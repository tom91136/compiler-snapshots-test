package uob_hpc.snapshots

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.StandardOpenOption
import java.time.Instant
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.IsoFields
import scala.collection.immutable.ArraySeq
import scala.collection.immutable.VectorMap
import scala.jdk.CollectionConverters.*
import scala.util.Try
import scala.util.Using
import org.eclipse.jgit.api.Git
import org.eclipse.jgit.api.errors.TransportException
import org.eclipse.jgit.lib.{Constants, Ref}
import org.eclipse.jgit.revwalk.RevCommit
import org.eclipse.jgit.transport.TagOpt
import org.eclipse.jgit.treewalk.TreeWalk
import org.eclipse.jgit.treewalk.filter.PathFilter

def writeText(xs: String, path: Path) = Files.writeString(
  path,
  xs,
  StandardOpenOption.TRUNCATE_EXISTING,
  StandardOpenOption.CREATE,
  StandardOpenOption.WRITE
)

final val GHAMaxJobCount = 256

type PIdentF[A] = PartialFunction[A, A]

case class Config(
    name: String,
    mirror: String,
    tags: PIdentF[(String, Ref)],
    branches: PIdentF[(String, Ref)],
    filter: String => Boolean,
    requirePath: Option[String] = None
)

// Released GCC will be in a branch: refs/heads/releases/gcc-$ver.
// Unreleased GCC won't have a branch but we can query refs/tags/basepoints/gcc-$ver which marks
// the first commit, we can then do a ranged log between the basepoint with HEAD
val GCC = Config(
  name = "gcc",
  mirror = "https://github.com/gcc-mirror/gcc.git",
  tags = { case (s"refs/tags/basepoints/gcc-$ver", ref) => ver -> ref },
  branches = { case (s"refs/heads/releases/gcc-$ver", ref) => ver -> ref },
  filter = _.toIntOption.exists(_ >= 8)
)

// LLVM has a similar pattern to GCC with basepoints and release branches for version >= 10.
// There's an additional consideration when LLVM integrates other subprojects into the monorepo.
// In this situation, any subproject commits leading to the merge will appear to be part of the LLVM
// tree but without any of the monorepo's files.
// To work around this, we must clone with trees and then check to see whether the expected paths
// exists to filter out any commits with no buildable sources.
val LLVM = Config(
  name = "llvm",
  mirror = "https://github.com/llvm/llvm-project.git",
  tags = { case (s"refs/tags/llvmorg-$ver-init", ref) => ver -> ref },
  branches = { case (s"refs/heads/release/$ver.x", ref) => ver -> ref },
  // XXX We must start after 10 because the `llvmorg-$ver-init` tag format is only introduced
  // in that version, see https://github.com/llvm/llvm-project/releases/tag/llvmorg-10-init
  filter = _.toIntOption.exists(_ >= 10),
  requirePath = Some("llvm/CMakeLists.txt")
)

object Generator {

  def main(args: Array[String]): Unit = {

    sys.props += ("org.slf4j.simpleLogger.logFile" -> "System.out")

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
      .sortBy(_._1.toIntOption)
      .flatMap { case (ver, basepoint) =>
        val repo    = git.getRepository
        val reader  = repo.newObjectReader()
        val endSpec = branches.get(ver) match {
          case Some(branchRef) => branchRef.getName
          case None            => Constants.HEAD
        }
        val endRef = repo.resolve(endSpec)
        println(s"Basepoint=$basepoint => Branch=$endSpec ($endRef)")
        val commits =
          git
            .log()
            .addRange(basepoint.getPeeledObjectId, endRef)
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
                  val message = c.getShortMessage.replace("\n", "\\n")
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
      .map(b =>
        s"${b.version}.${b.date.atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ISO_DATE)}.${b.shortHash}" -> b
      )
      .to(VectorMap)

    // val releasedBuilds = fetchReleases(repoOwner, repoName).map(_.tag_name).toSet
    // XXX GH limits the release API to max 1000 entries regardless of items per page or page count
    //   To workaround this, we list the Git tags which is required for a release and doesn't have
    //   arbitrary API limits.
    val releasedBuilds = Try {
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

    val missingBuilds = builds.filterNot { case (k, _) => releasedBuilds.contains(k) }

    val matrix = if (missingBuilds.nonEmpty) {
      val buildsPerJob = (missingBuilds.size.toDouble / GHAMaxJobCount).ceil.toInt
      val jobGrouped   = missingBuilds.sliding(buildsPerJob, buildsPerJob).map(_.keys.mkString(";")).toList
      println(s"Computed builds = ${builds.size}")
      println(s"Released builds = ${releasedBuilds.size}")
      println(s"Required builds = ${missingBuilds.size}")
      println(s"       Max jobs = $GHAMaxJobCount")
      println(s" Builds Per job = $buildsPerJob")
      println(s"     Total jobs = ${jobGrouped.size}")
      jobGrouped
    } else Nil

    // XXX spaces break ::set-output in the action yaml for some reason, so no pretty print
    writeText(Pickler.write(matrix), Paths.get(s"matrix-${config.name}.json"))
    writeText(Pickler.write(builds.to(Map)), Paths.get(s"builds-${config.name}.json"))
    writeText(Pickler.write(missingBuilds.keys.toList), Paths.get(s"missing-${config.name}.json"))
    println("Build computed")

    if (generateApi) {
      val parent = Files.createDirectories(Paths.get(config.name))
      println(s"Generating static APIs ($builds files) in $parent")
      builds.foreach { case (name, b) =>
        writeText(Pickler.write(b), parent.resolve(s"$name.json"))
      }
      println("API generated")
    }
  }
}
