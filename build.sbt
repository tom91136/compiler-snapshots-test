import java.nio.file.Files
import java.nio.file.StandardCopyOption.REPLACE_EXISTING

import org.scalajs.linker.interface.ESFeatures
import org.scalajs.linker.interface.ESVersion

Global / onChangedBuildSource := ReloadOnSourceChanges

lazy val start = TaskKey[Unit]("start")
lazy val dist  = TaskKey[File]("dist")

lazy val scala3Version  = "3.7.2"
lazy val upickleVersion = "4.2.1"
lazy val munitVersion   = "1.0.0-M5"

lazy val commonSettings = Seq(
  scalaVersion     := scala3Version,
  version          := "0.0.1-SNAPSHOT",
  organization     := "uk.ac.bristol.uob-hpc",
  organizationName := "University of Bristol",
//  scalacOptions ~= filterConsoleScalacOptions,
  javacOptions ++=
    Seq(
      "-parameters",
      "-Xlint:all"
    ) ++
      Seq("-source", "1.8") ++
      Seq("-target", "1.8"),
  scalacOptions ++= Seq(
    "-Wunused:all",                              //
    "-no-indent",                                //
    "-Wconf:cat=unchecked:error",                //
    "-Wconf:name=MatchCaseUnreachable:error",    //
    "-Wconf:name=PatternMatchExhaustivity:error" //
    // "-language:strictEquality"
  ),
  scalafmtDetailedError                  := true,
  scalafmtFailOnErrors                   := true,
  Compile / packageDoc / publishArtifact := false,
  Compile / doc / sources                := Seq(),
  (Compile / tpolecatExcludeOptions) ++= ScalacOptions.defaultConsoleExclude
)

lazy val model = crossProject(JSPlatform, JVMPlatform)
  .settings(
    commonSettings,
    name := "model",
    libraryDependencies ++= Seq("com.lihaoyi" %%% "upickle" % upickleVersion)
  )

lazy val generator = project
  .settings(
    commonSettings,
    name := "generator",
    libraryDependencies ++= Seq(
      "org.slf4j"        % "slf4j-simple"     % "2.0.17",
      "org.eclipse.jgit" % "org.eclipse.jgit" % "7.3.0.202506031305-r",
      "com.lihaoyi"     %% "upickle"          % upickleVersion
    ),
    Compile / packageBin / mainClass := Some("uob_hpc.Main"),
    assemblyMergeStrategy            := {
      case PathList("META-INF", "versions", "9", "module-info.class") => MergeStrategy.discard
      case x                                                          =>
        val oldStrategy = (ThisBuild / assemblyMergeStrategy).value
        oldStrategy(x)
    }
  )
  .dependsOn(model.jvm)

lazy val webapp = project
  .enablePlugins(ScalaJSPlugin, ScalablyTypedConverterPlugin)
  .settings(
    commonSettings,
    name                            := "webapp",
    scalaJSUseMainModuleInitializer := true,
    Compile / watchTriggers += (baseDirectory.value / "src/main/js/public").toGlob / "*.*",
    scalaJSLinkerConfig ~= ( //
      _.withSourceMap(false)
        .withModuleKind(ModuleKind.CommonJSModule)
        .withESFeatures(ESFeatures.Defaults.withESVersion(ESVersion.ES2015))
        .withParallel(true)
    ),
    useYarn                         := true,
    webpackDevServerPort            := 8001,
    stUseScalaJsDom                 := true,
    webpack / version               := "5.73.0",
    webpackCliVersion               := "4.10.0",
    startWebpackDevServer / version := "4.9.3",
    Compile / fastOptJS / webpackExtraArgs += "--mode=development",
    Compile / fullOptJS / webpackExtraArgs += "--mode=production",
    Compile / fastOptJS / webpackDevServerExtraArgs += "--mode=development",
    Compile / fullOptJS / webpackDevServerExtraArgs += "--mode=production",
    webpackConfigFile := Some((ThisBuild / baseDirectory).value / "webpack.config.mjs"),
    libraryDependencies ++= Seq(
      "org.scala-js"      %%% "scalajs-dom"     % "2.8.1",
      "io.github.cquiroz" %%% "scala-java-time" % "2.6.0", // ignore timezones
      "com.raquo"         %%% "laminar"         % "17.2.1",
      "com.raquo"         %%% "waypoint"        % "9.0.0"
    ),
    stIgnore ++= List(
      "node",
      "bulma",
      "@fortawesome/fontawesome-free"
    ),
    Compile / npmDependencies ++= Seq(
      // CSS and layout
      "@fortawesome/fontawesome-free" -> "5.15.4",
      "bulma"                         -> "0.9.4"
    ),
    Compile / npmDevDependencies ++= Seq(
      "webpack-merge" -> "5.8.0",
      "css-loader"    -> "6.7.1",
      "style-loader"  -> "3.3.1",
      "file-loader"   -> "6.2.0",
      "url-loader"    -> "1.1.2",
      "html-loader"   -> "4.1.0"
    )
  )
  .settings(
    start :=
      (Compile / fastOptJS / startWebpackDevServer).value,
    dist := {
      val artifacts      = (Compile / fullOptJS / webpack).value
      val artifactFolder = (Compile / fullOptJS / crossTarget).value
      val distFolder     = (ThisBuild / baseDirectory).value / "docs"

      distFolder.mkdirs()
      IO.deleteFilesEmptyDirs(Seq(distFolder.file))

      artifacts.foreach { artifact =>
        val target = artifact.data.relativeTo(artifactFolder) match {
          case None          => distFolder / artifact.data.name
          case Some(relFile) => distFolder / relFile.toString
        }
        IO.copy(
          Seq(artifact.data.file -> target),
          overwrite = true,
          preserveLastModified = true,
          preserveExecutable = false
        )
      }

      val index           = "index.html"
      val publicResources = baseDirectory.value / "src/main/js/public/"

      Files.list(publicResources.toPath).filter(_.getFileName.toString != index).forEach { p =>
        Files.copy(p, (distFolder / p.getFileName.toString).toPath, REPLACE_EXISTING)
      }

      val indexFrom = publicResources / index
      val indexTo   = distFolder / index

      val indexPatchedContent = {
        import collection.JavaConverters._
        Files
          .readAllLines(indexFrom.toPath, IO.utf8)
          .asScala
          .map(_.replaceAllLiterally("-fastopt-", "-opt-"))
          .mkString("\n")
      }

      Files.write(indexTo.toPath, indexPatchedContent.getBytes(IO.utf8))
      distFolder
    }
  )
  .dependsOn(model.js)

lazy val root = project
  .in(file("."))
  .settings(commonSettings)
  .aggregate(generator, model.jvm, model.js, webapp)
