package uob_hpc.snapshots

import org.eclipse.jgit.api.Git
import org.eclipse.jgit.api.errors.TransportException
import org.eclipse.jgit.lib.{Constants, ObjectId, Ref, Repository}
import org.eclipse.jgit.revwalk.{RevCommit, RevWalk}
import org.eclipse.jgit.revwalk.filter.RevFilter
import org.eclipse.jgit.transport.TagOpt
import org.eclipse.jgit.treewalk.TreeWalk
import org.eclipse.jgit.treewalk.filter.PathFilter

import java.nio.file.{Files, Path, Paths, StandardOpenOption}
import java.time.{Instant, ZoneOffset, ZonedDateTime}
import java.time.temporal.IsoFields
import scala.collection.immutable.ArraySeq
import scala.collection.parallel.CollectionConverters.*
import scala.jdk.CollectionConverters.*
import scala.util.{Try, Using}

def writeText(xs: String, path: Path): Unit = Files.writeString(
  path,
  xs,
  StandardOpenOption.TRUNCATE_EXISTING,
  StandardOpenOption.CREATE,
  StandardOpenOption.WRITE
): Unit

final val GHAMaxJobCount = 256

type IdPartialFn[A] = PartialFunction[A, A]

case class Config(
    name: String,
    mirror: String,
    arches: Vector[String],
    basepointTags: IdPartialFn[(String, Ref)],
    versionBranches: IdPartialFn[(String, Ref)],
    filter: (String, String) => Boolean,
    requirePath: Option[String] = None
)

// Released GCC will be in a branch: refs/heads/releases/gcc-$ver.
// Unreleased GCC won't have a branch, but we can query refs/tags/basepoints/gcc-$ver which marks
// the first commit, we can then do a ranged log between the basepoint with HEAD
val GCC = Config(
  name = "gcc",
  mirror = "https://github.com/gcc-mirror/gcc.git",
  arches = Vector("x86_64", "aarch64", "ppc64le"),
  basepointTags = {
    case (s"refs/tags/basepoints/gcc-$ver", ref)                                       => ver          -> ref
    case (s"refs/tags/releases/gcc-$maj.$min.0", ref) if maj.toIntOption.exists(_ < 5) => s"$maj.$min" -> ref
  },
  versionBranches = { case (s"refs/heads/releases/gcc-$ver", ref) => ver -> ref },
  filter = { // see https://gcc.gnu.org/releases.html
    case (ver, "x86_64")  => ver.toFloatOption.exists(_ >= 4.0)
    case (ver, "aarch64") => ver.toFloatOption.exists(_ >= 4.8) // aarch64 only really worked after 4.8
    case (ver, "ppc64le") => ver.toFloatOption.exists(_ >= 5.0) // ppc64le needed IBM patches in 4.8~4.9
    case (_, arch)        => throw IllegalArgumentException(s"Unsupported arch: $arch")
  }
)

// LLVM has a similar pattern to GCC with basepoints and release branches for version >= 10.
// There's an additional consideration when LLVM integrates other subprojects into the monorepo.
// In this situation, any subproject commits leading to the merge will appear to be part of the LLVM
// tree but without any of the monorepo's files.
// To work around this, we must clone with trees and then check to see whether the expected paths
// exist to filter out any commits with no buildable sources.
val LLVM = Config(
  name = "llvm",
  mirror = "https://github.com/llvm/llvm-project.git",
  arches = Vector("x86_64", "aarch64", "ppc64le"),
  basepointTags = {
    case (s"refs/tags/llvmorg-$maj.$min.$_", ref) if min.forall(_.isDigit) && maj.toIntOption.exists(_ <= 3) =>
      s"$maj.$min" -> ref // <= 3.x series, no basepoints and keep minor
    case (s"refs/tags/llvmorg-$maj.$_.$_", ref) if maj.forall(_.isDigit) && maj.toInt < 10 =>
      maj -> ref // < 10 series, use major only
    case (s"refs/tags/llvmorg-$ver-init", ref) => ver -> ref // >= 10, use explicit init tag used as basepoint

  },
  versionBranches = { case (s"refs/heads/release/$ver.x", ref) => ver -> ref },
  filter = { // see https://releases.llvm.org/
    case (ver, "x86_64")  => ver.toFloatOption.exists(_ >= 3.0f)
    case (ver, "aarch64") => ver.toFloatOption.exists(_ >= 3.6f)
    case (ver, "ppc64le") => ver.toFloatOption.exists(_ >= 3.6f)
    case (_, arch)        => throw IllegalArgumentException(s"Unsupported arch: $arch")
  },
  requirePath = Some("llvm/CMakeLists.txt")
)

def resolveFirst(repo: Repository, refs: String*): ObjectId = refs.view
  .map(repo.resolve)
  .find(_ != null)
  .getOrElse {
    throw IllegalStateException(s"None of ${refs.mkString(", ")} exist in ${repo.getDirectory}")
  }

def mergeBase(repo: Repository, a: ObjectId, b: ObjectId): RevCommit = Using(RevWalk(repo)) { walk =>
  walk.setRevFilter(RevFilter.MERGE_BASE)
  walk.markStart(walk.parseCommit(a))
  walk.markStart(walk.parseCommit(b))
  val base = walk.next()
  if (base == null) throw IllegalStateException("No merge-base found")
  base
}.get

def resolveIgnores(git: Git, f: Path): Vector[(String, Vector[RevCommit])] =
  if (!Files.isRegularFile(f)) Vector.empty
  else {
    val repo = git.getRepository
    scribe.info(s"Reading ignore file: $f")
    val resolved = Files
      .readAllLines(f)
      .asScala
      .map(_.trim)
      .filterNot(_.isBlank())
      .filterNot(_.startsWith("#"))
      .distinct
      .sorted
      .toVector.map {
        case x @ s"$start..$end" =>
          val startParents = Using(RevWalk(repo))(_.parseCommit(repo.resolve(start))).get.getParents
          if (startParents.size != 1) {
            throw RuntimeException(s"Ignored commit range $start has zero or more than one parents")
          }
          x -> git
            .log()
            .addRange(startParents.head, repo.resolve(end))
            .call()
            .asScala
            .toVector
        case x => x -> Vector(Using(RevWalk(repo))(_.parseCommit(repo.resolve(x))).get)
      }

    scribe.info(
      s"Ignoring the following commits for $f:\n${
          resolved.map { (raw, xs) =>
            val head = xs.head
            val last = xs.last
            s"$raw => ${xs.size} commits (${last.getAuthorIdent.getWhenAsInstant} => ${head.getAuthorIdent.getWhenAsInstant}}) "
          }.mkString("\n")
        }"
    )
    resolved
  }

@main def main(configName: String, generateApi: Boolean = false): Unit = {

  val config = configName.toLowerCase match {
    case "llvm" => LLVM
    case "gcc"  => GCC
    case _      => scribe.error(s"Unsupported config: $configName"); sys.exit(1)
  }

  def exec(xs: String*) = {
    scribe.info(s"> ${xs.mkString(" ")}")
    sys.process.Process(xs).! : Unit
  }

  val repoDir = Paths.get(s"./${config.name}-bare").normalize().toAbsolutePath
  // jgit can't fetch bare
  if (!Files.exists(repoDir)) {
    exec(
      "git",
      "clone",
      "--progress",
      "--bare",
      "--no-checkout",
      s"--filter=${if (config.requirePath.isDefined) "blob:none" else "tree:0"}",
      config.mirror,
      repoDir.toString
    )
  } else {
    exec("git", "-C", repoDir.toString, "fetch", "origin")
  }

  val git = Git.open(repoDir.toFile)

  val now                = ZonedDateTime.now()
  val currentYearAndWeek = (now.get(IsoFields.WEEK_BASED_YEAR), now.get(IsoFields.WEEK_OF_WEEK_BASED_YEAR))

  // val releasedBuilds = fetchReleases(repoOwner, repoName).map(_.tag_name).toSet
  // XXX GH limits the release API to max 1000 entries regardless of items per page or page count
  //   To work around this, we list the Git tags which is required for a release and doesn't have
  //   arbitrary API limits.
  val releasedBuildsWithArch = Try {
    val localRepo = Git.open(Paths.get(".").toFile)
    localRepo.fetch().setTagOpt(TagOpt.FETCH_TAGS).setDepth(1).call()
    localRepo
      .tagList()
      .call()
      .asScala
      .map(_.getName.stripPrefix("refs/tags/"))
      .toSet
  }.recover { case e: TransportException =>
    scribe.error(s"Using empty tag list: ${e.getMessage}")
    Set.empty[String]
  }.get

  scribe.info(s"Released Builds = ${releasedBuildsWithArch.size} (total)")
  scribe.info(s"Max Jobs =        $GHAMaxJobCount")

  val sharedIgnores = resolveIgnores(git, Paths.get(s"./ignore_commits.${config.name}"))
  val archBuilds = config.arches.par.map { arch =>
    val repo               = git.getRepository
    val ignoreCommits      = sharedIgnores ++ resolveIgnores(git, Paths.get(s"./ignore_commits.${config.name}.$arch"))
    val ignoredCommitNames = ignoreCommits.flatMap(_._2.map(_.getName))

    val basepoints = git
      .tagList()
      .call()
      .asScala
      .map(r => r.getName -> r)
      .collect(config.basepointTags)
      .filter(x => config.filter(x._1, arch))
      .toMap

    val branches = git
      .branchList()
      .call()
      .asScala
      .map(r => r.getName -> r)
      .collect(config.versionBranches)
      .filter(x => config.filter(x._1, arch))
      .toMap

    val builds = basepoints.toVector
      .sortBy(_._1.toFloatOption)
      .flatMap { case (ver, basepoint) =>
        val reader  = repo.newObjectReader()
        val head    = resolveFirst(repo, "refs/heads/main", "refs/heads/master", "refs/heads/trunk", Constants.HEAD)
        val endSpec = branches.get(ver) match {
          case Some(branchRef) => branchRef.getName
          case None            => head.getName
        }
        val endRef        = repo.resolve(endSpec)
        val basepointSpec = basepoint.getName match {
          case s"$_-init" | s"$_/tags/basepoints/$_" => Option(basepoint.getPeeledObjectId)
          case _                                     => None
        }
        val startRef = basepointSpec.getOrElse(mergeBase(repo, head, endRef))

        scribe.info(s"[$arch] Ver=$ver Basepoint=$basepointSpec $startRef=> Branch=$endSpec ($endRef)")

        val commits =
          git
            .log()
            .addRange(startRef, endRef)
            .call()
            .asScala
            .toVector
            .sortBy(_.getCommitTime)

        val grouped = commits
          .filterNot(c => ignoredCommitNames.exists(c.getName.startsWith(_)))
          .filter(c =>
            c.getParents.toList match {
              case p :: Nil => p.getCommitTime <= c.getCommitTime
              case _        => false
            }
          )
          .filter { c =>
            config.requirePath match {
              case None       => true
              case Some(path) =>
                Using(TreeWalk(repo)) { walk =>
                  walk.addTree(c.getTree)
                  walk.setRecursive(true)
                  walk.setFilter(PathFilter.create(path))
                  walk.next() // true (file exists) if the commit is buildable
                }.get
            }
          }
          .map(c => c -> c.getCommitterIdent)
          .groupBy {
            case (_, ident) => // group by (YYYY, WW)
              val time = ident.getWhenAsInstant.atOffset(ZoneOffset.UTC)
              time.get(IsoFields.WEEK_BASED_YEAR) -> time.get(IsoFields.WEEK_OF_WEEK_BASED_YEAR)
          }
          .toList
          .sortBy(_._1)
          .flatMap {
            // Last commit of the week iff it's not from this week.
            // We ignore the current week otherwise we end up with the last commit of the currently in-progress week.
            case (yearAndWeek, xs) if yearAndWeek != currentYearAndWeek =>
              xs.maxByOption(_._2.getWhenAsInstant.toEpochMilli)
            case _ => None
          }
          .scanLeft[Option[(RevCommit, Build)]](None) { case (origin, (c, ident)) =>
            val changes = origin match {
              case None         => ArraySeq.empty[(RevCommit, Instant, String)]
              case Some((x, _)) =>
                commits.dropWhile(_ != x).takeWhile(_ != c).reverse.to(ArraySeq).map { c =>
                  val date    = c.getCommitterIdent.getWhenAsInstant
                  val message = c.getShortMessage.replace("\n", "\\n").replace("`", "\\`")
                  (c, date, message)
                }
            }
            Some(
              c -> Build(
                version = s"${config.name}-$ver",
                date = ident.getWhenAsInstant,
                hash = c.name(),
                hashLength = reader.abbreviate(c).name().length,
                parent = changes.headOption.map((c, _, _) => reader.abbreviate(c).name()),
                changes = changes.map((c, date, message) => (reader.abbreviate(c).name(), date, message)),
                zeroChanges = config.name == "gcc" && changes.forall(_._3 == "Daily bump.")
              )
            )
          }
          .collect { case Some((_, x)) => x }
        reader.close()
        grouped
      }

    val missing =
      builds
        .filterNot(_.zeroChanges)
        .map(_.fmtWithArch(arch))
        .filterNot(releasedBuildsWithArch.contains(_))

    arch -> (builds, missing)
  }.seq

  val allMissing   = archBuilds.flatMap(_._2._2)
  val buildsPerJob = (allMissing.length.toDouble / GHAMaxJobCount).ceil.toInt

  archBuilds.foreach { case (arch, (allBuilds, pending)) =>

    val builds = allBuilds.filterNot(_.zeroChanges)

    scribe.info(s"[$arch] Zero Change Builds = ${allBuilds.count(_.zeroChanges)} (total)")
    scribe.info(s"[$arch] Computed Builds = ${builds.size} (total, non-zero)")
    scribe.info(s"[$arch] Builds Per Job =  $buildsPerJob")

    val matrix = if (pending.nonEmpty) {
      val jobGrouped = pending.grouped(buildsPerJob).map(_.mkString(";")).toList
      scribe.info(s"[$arch] Pending Builds =  ${pending.size}")
      scribe.info(s"[$arch] Total Jobs =      ${jobGrouped.size}")
      jobGrouped
    } else Nil

    writeText(
      Pickler.write(allBuilds.map(_.fmtWithArch(arch)), indent = 2),
      Paths.get(s"all-${config.name}-$arch.json")
    )

    // XXX spaces break ::set-output in the action yaml for some reason, so no pretty print
    writeText(Pickler.write(matrix), Paths.get(s"matrix-${config.name}-$arch.json"))
    writeText(
      Pickler.write(builds.map(b => b.fmtNoArch -> b).to(Map)),
      Paths.get(s"builds-${config.name}-$arch.json")
    )
    writeText(Pickler.write(pending), Paths.get(s"missing-${config.name}-$arch.json"))
  }

  scribe.info("Build computed")

  if (generateApi) {
    val allBuilds = archBuilds.flatMap(_._2._1).distinct
    val parent    = Files.createDirectories(Paths.get(config.name))
    scribe.info(s"Generating static APIs (${allBuilds.size} entries) in $parent")
    allBuilds.foreach { b =>
      writeText(Pickler.write(b), parent.resolve(s"${b.fmtNoArch}.json"))
    }
    scribe.info("API generated")
  }
}
