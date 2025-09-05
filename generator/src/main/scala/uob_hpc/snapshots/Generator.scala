package uob_hpc.snapshots

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.StandardOpenOption
import java.time.Instant
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.temporal.IsoFields
import scala.collection.immutable.ArraySeq
import scala.jdk.CollectionConverters.*
import scala.util.Try
import scala.util.Using

import org.eclipse.jgit.api.Git
import org.eclipse.jgit.api.errors.TransportException
import org.eclipse.jgit.lib.Constants
import org.eclipse.jgit.lib.ObjectId
import org.eclipse.jgit.lib.Ref
import org.eclipse.jgit.revwalk.RevCommit
import org.eclipse.jgit.revwalk.RevWalk
import org.eclipse.jgit.revwalk.filter.RevFilter
import org.eclipse.jgit.transport.TagOpt
import org.eclipse.jgit.treewalk.TreeWalk
import org.eclipse.jgit.treewalk.filter.PathFilter

def writeText(xs: String, path: Path): Unit = Files.writeString(
  path,
  xs,
  StandardOpenOption.TRUNCATE_EXISTING,
  StandardOpenOption.CREATE,
  StandardOpenOption.WRITE
): Unit

final val GHAMaxJobCount = 128

type PIdentF[A] = PartialFunction[A, A]

case class Config(
    name: String,
    mirror: String,
    arches: Vector[String],
    tags: PIdentF[(String, Ref)],
    branches: PIdentF[(String, Ref)],
    filter: String => Boolean,
    requirePath: Option[String] = None
)

// Released GCC will be in a branch: refs/heads/releases/gcc-$ver.
// Unreleased GCC won't have a branch, but we can query refs/tags/basepoints/gcc-$ver which marks
// the first commit, we can then do a ranged log between the basepoint with HEAD
val GCC = Config(
  name = "gcc",
  mirror = "https://github.com/gcc-mirror/gcc.git",
  arches = Vector("x86_64", "aarch64"),
  tags = { case (s"refs/tags/basepoints/gcc-$ver", ref) => ver -> ref },
  branches = { case (s"refs/heads/releases/gcc-$ver", ref) => ver -> ref },
  filter = _.toIntOption.exists(_ >= 5)
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
  arches = Vector("x86_64", "aarch64"),
  tags = {
    case (s"refs/tags/llvmorg-$maj.$min.$_", ref) if min.forall(_.isDigit) && maj.toIntOption.exists(_ <= 3) =>
      s"$maj.$min" -> ref // <= 3.x series, no basepoints and keep minor
    case (s"refs/tags/llvmorg-$maj.$_.$_", ref) if maj.forall(_.isDigit) && maj.toInt < 10 =>
      maj -> ref // < 10 series, use major only
    case (s"refs/tags/llvmorg-$ver-init", ref) => ver -> ref // >= 10, use explicit init tag used as basepoint
  },
  branches = { case (s"refs/heads/release/$ver.x", ref) => ver -> ref },
  filter = _.toFloatOption.exists(_ >= 3.6f),
  requirePath = Some("llvm/CMakeLists.txt")
)

def resolveFirst(repo: org.eclipse.jgit.lib.Repository, refs: String*): ObjectId =
  refs.view
    .map(repo.resolve)
    .find(_ != null)
    .getOrElse {
      throw new IllegalStateException(s"None of ${refs.mkString(", ")} exist in ${repo.getDirectory}")
    }

def mergeBase(repo: org.eclipse.jgit.lib.Repository, a: ObjectId, b: ObjectId): RevCommit = {
  val walk = new RevWalk(repo)
  try {
    walk.setRevFilter(RevFilter.MERGE_BASE)
    walk.markStart(walk.parseCommit(a))
    walk.markStart(walk.parseCommit(b))
    val base = walk.next()
    if (base == null) throw new IllegalStateException("No merge-base found")
    base
  } finally walk.close()
}

object Generator {

  def main(args: Array[String]): Unit = {

    sys.props += ("org.slf4j.simpleLogger.logFile" -> "System.out"): Unit

    val ignoreCommits = Files
      .readAllLines(Paths.get("./ignore_commits"))
      .asScala
      .map(_.trim)
      .filterNot(_.isBlank())
      .filterNot(_.startsWith("#"))
      .distinct
      .sorted
      .toSeq

    println(s"Ignoring the following commits: \n${ignoreCommits.mkString("\n")}")

    val (config, _, _, generateApi) = args.toList match {
      case config :: s"$repoOwner/$repoName" :: xs if xs.size <= 1 =>
        (
          config.toLowerCase match {
            case "llvm" => LLVM
            case "gcc"  => GCC
            case _      => Console.err.println(s"Unsupported config: $config"); sys.exit(1)
          },
          repoOwner,
          repoName,
          xs.contains("true")
        )
      case bad =>
        Console.err.println(
          s"Bad arg `${bad.mkString(" ")}`, expecting `config:string repoOwner:string repoName:string api:(true|false)?`"
        )
        sys.exit(1)
    }

    val repoDir = Paths.get(s"./${config.name}-bare").normalize().toAbsolutePath
    if (!Files.exists(repoDir)) {
      sys.process.Process(
        Seq(
          "git",
          "clone",
          "--progress",
          "--bare",
          "--no-checkout",
          s"--filter=${if (config.requirePath.isDefined) "blob:none" else "tree:0"}",
          config.mirror,
          repoDir.toString
        )
      ).! : Unit
    }

    val git = Git.open(repoDir.toFile)

    val basepoints = git
      .tagList()
      .call()
      .asScala
      .map(r => r.getName -> r)
      .collect(config.tags)
      .filter(x => config.filter(x._1))
      .toMap

    val branches = git
      .branchList()
      .call()
      .asScala
      .map(r => r.getName -> r)
      .collect(config.branches)
      .filter(x => config.filter(x._1))
      .toMap

    val now                = ZonedDateTime.now()
    val currentYearAndWeek = (now.get(IsoFields.WEEK_BASED_YEAR), now.get(IsoFields.WEEK_OF_WEEK_BASED_YEAR))

    val builds = basepoints.toVector
      .sortBy(_._1.toFloatOption)
      .flatMap { case (ver, basepoint) =>
        val repo    = git.getRepository
        val reader  = repo.newObjectReader()
        val head    = resolveFirst(repo, "refs/heads/main", "refs/heads/master", "refs/heads/trunk", Constants.HEAD)
        val endSpec = branches.get(ver) match {
          case Some(branchRef) => branchRef.getName
          case None            => head.getName
        }
        val endRef        = repo.resolve(endSpec)
        val basepointSpec = basepoint.getName match {
          case s"$_-init" => Option(basepoint.getPeeledObjectId)
          case _          => None
        }
        val startRef = basepointSpec.getOrElse(mergeBase(repo, head, endRef))

        println(s"Ver=$ver Basepoint=$basepointSpec $startRef=> Branch=$endSpec ($endRef)")

        val commits =
          git
            .log()
            .addRange(startRef, endRef)
            .call()
            .asScala
            .toVector
            .sortBy(_.getCommitTime)

        val grouped = commits
          .filterNot(c => ignoreCommits.exists(c.getName.startsWith(_)))
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
              case None         => ArraySeq.empty[(String, Instant, String)]
              case Some((x, _)) =>
                commits.dropWhile(_ != x).takeWhile(_ != c).reverse.to(ArraySeq).map { c =>
                  val hash    = reader.abbreviate(c).name()
                  val date    = c.getCommitterIdent.getWhenAsInstant
                  val message = c.getShortMessage.replace("\n", "\\n").replace("`", "\\`")
                  (hash, date, message)
                }
            }
            Some(
              c -> Build(
                version = s"${config.name}-$ver",
                date = ident.getWhenAsInstant,
                hash = c.name(),
                hashLength = reader.abbreviate(c).name().length,
                changes = changes
              )
            )
          }
          .collect { case Some((_, x)) => x }
        reader.close()
        grouped
      }

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
      Console.err.println(s"Using empty tag list: ${e.getMessage}")
      Set.empty[String]
    }.get

    val missingBuilds = builds
      .flatMap(b => config.arches.map(b.fmtWithArch(_)))
      .filterNot(releasedBuildsWithArch.contains(_))

    val matrix = if (missingBuilds.nonEmpty) {
      val buildsPerJob = (missingBuilds.size.toDouble / GHAMaxJobCount).ceil.toInt
      val jobGrouped   = missingBuilds.grouped(buildsPerJob).map(_.mkString(";")).toList
      println(s"Computed builds = ${builds.size} (platform independent)")
      println(s"Released builds = ${releasedBuildsWithArch.size} (platform dependent)")
      println(s"Required builds = ${missingBuilds.size} (platform dependent)")
      println(s"       Max jobs = $GHAMaxJobCount")
      println(s" Builds Per job = $buildsPerJob")
      println(s"     Total jobs = ${jobGrouped.size}")
      jobGrouped
    } else Nil

    // XXX spaces break ::set-output in the action yaml for some reason, so no pretty print
    writeText(Pickler.write(matrix), Paths.get(s"matrix-${config.name}.json"))
    writeText(Pickler.write(builds.map(b => b.fmtNoArch -> b).to(Map)), Paths.get(s"builds-${config.name}.json"))
    writeText(Pickler.write(missingBuilds), Paths.get(s"missing-${config.name}.json"))
    println("Build computed")

    if (generateApi) {
      val parent = Files.createDirectories(Paths.get(config.name))
      println(s"Generating static APIs (${builds.size} entries) in $parent")
      builds.foreach { b =>
        writeText(Pickler.write(b), parent.resolve(s"${b.fmtNoArch}.json"))
      }
      println("API generated")
    }
  }
}
