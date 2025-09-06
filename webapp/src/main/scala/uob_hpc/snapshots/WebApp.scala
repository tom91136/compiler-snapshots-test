package uob_hpc.snapshots

import com.raquo.airstream.state.Var
import com.raquo.laminar.api.L.*
import com.raquo.waypoint.*
import org.scalajs.dom
import org.scalajs.dom.window
import uob_hpc.snapshots.Pickler.*

import java.time.{Instant, ZoneOffset}
import java.time.format.DateTimeFormatter
import scala.collection.immutable.ArraySeq
import scala.concurrent.ExecutionContext.Implicits.global
import scala.scalajs.js
import scala.scalajs.js.annotation.JSImport
import scala.util.{Failure, Success}

object WebApp {

  private case class Index(build: Option[String] = None) derives ReadWriter

  private object router extends Router[Index](
        routes = List(
          Route.onlyFragment[Index, Option[String]](
            _.build,
            Index(_),
            (root / endOfSegments).withFragment(maybeFragment[String]),
            s"${window.location.pathname}#"
          )
        ),
        getPageTitle = p => s"Compiler snapshots${p.build.fold("")(x => s" - $x")}",
        serializePage = Pickler.web.write(_),
        deserializePage = Pickler.web.read[Index](_)
      )

  private def navigateTo(page: Index, replace: Boolean = false): Binder[HtmlElement] = Binder { el =>
    val isLinkElement = el.ref.isInstanceOf[dom.html.Anchor]
    if (isLinkElement)
      el.amend(href(router.relativeUrlForPage(page)))
    (onClick
      .filter(ev => !(isLinkElement && (ev.ctrlKey || ev.metaKey || ev.shiftKey || ev.altKey)))
      .preventDefault
      --> (_ => if (replace) router.replaceState(page) else router.pushState(page))).bind(el)
  }

  @JSImport("bulma/css/bulma.min.css", JSImport.Namespace)
  @js.native
  private object Bulma extends js.Object

  @JSImport("@fortawesome/fontawesome-free/css/all.css", JSImport.Namespace)
  @js.native
  private object FontAwesomeCSS extends js.Object

  private enum Compiler(val repo: String) {
    case GCC  extends Compiler("gcc-mirror/gcc")
    case LLVM extends Compiler("llvm/llvm-project")
  }

  @main def main(): Unit = {

    // XXX keep a reference to these
    val _ = (Bulma, FontAwesomeCSS)

    val lut      = Var[Map[String, (Build, Compiler)]](Map.empty)
    val archs    = Vector("x86_64", "aarch64")
    val builds   = Compiler.values.map(_ -> Var[Deferred[Map[String, Build]]](Deferred.Pending)).toMap
    val missings = Compiler.values.map(_ -> Var[Deferred[ArraySeq[String]]](Deferred.Pending)).toMap

    Compiler.values.foreach { c =>
      fetchJson[Map[String, Build]](s"./builds-${c.toString.toLowerCase}.json").onComplete(x =>
        builds(c).set(x match {
          case Failure(e)  => Deferred.Error(e)
          case Success(xs) =>
            lut.update(_ ++ xs.map((key, build) => key -> (build, c)))
            Deferred.Success(xs)
        })
      )
      fetchJson[ArraySeq[String]](s"./missing-${c.toString.toLowerCase}.json").onComplete(x =>
        missings(c).set(x match {
          case Failure(e)  => Deferred.Error(e)
          case Success(xs) => Deferred.Success(xs)
        })
      )
    }

    val globalStylesheet = dom.document.createElement("style")
    globalStylesheet.textContent = """
      |.highlight-row:hover {
      |  color: white;
      |  background-color: #3e8ed0 !important;
      |}
      |
      |.highlight-row {
      |  color: white !important;
      |  background-color: #3e8ed0;
      |}
	  |
	  |.missing-row {
      |  color: white !important;
      |  background-color: #f14668;
      |}
	  |
	  |.missing-partial-row {
      |  color: white !important;
      |  background-color: #f1c946;
      |}
      |
      |.extra-intro {
      |  font-size: 1em;
      |}
	  |
      |@media screen and (max-width: 768px) {
      |  .extra-intro {
      |    font-size: 0.6em;
      |  }
      |}
      |
      |""".stripMargin
    dom.document.head.append(globalStylesheet)

    val pageSplitter = SplitRender[Index, HtmlElement](router.currentPageSignal)
      .collectSignal[Index] { sig =>

        val compiler = Var[Compiler](Compiler.GCC)
        val filter   = Var[String]("")

        val buildSelection = articleTag(
          cls             := "panel is-info",
          border          := "1.5px solid #3e8ed0",
          borderRadius.px := 8,
          overflow.hidden,
          display.flex,
          flexDirection.column,
          maxHeight.percent := 100,
          p(cls := "panel-heading", s"Snapshots", fontSize.em := 0.9),
          div(
            cls             := "tabs is-boxed is-centered",
            flexShrink      := "0",
            marginBottom.px := 8,
            ul(Compiler.values.toSeq.map { c =>
              li(
                cls("is-active") <-- compiler.signal.map(_ == c),
                a(
                  child.text <-- missings(c).signal.combineWith(builds(c).signal).map {
                    case (Deferred.Success(missing), Deferred.Success(total)) =>
                      s"$c (${(total.size * archs.size) - missing.size})"
                    case _ => s"$c"
                  },
                  onClick.mapTo(c) --> compiler.writer
                )
              )
            })
          ),
          div(
            cls := "panel-block",
            p(
              cls := "control has-icons-left",
              input(
                cls         := "input is-link",
                tpe         := "text",
                placeholder := "Filter",
                controlled(value <-- filter, onInput.mapToValue --> filter)
              ),
              span(cls := "icon is-left", i(cls := "fas fa-filter", dataAttr("aria-hidden") := "true"))
            )
          ),
          Compiler.values.toSeq.map { c =>
            div(
              overflow.scroll,
              height.percent := 100,
              display <-- compiler.signal.map(_ == c).map(if (_) "block" else "none"),
              children <-- missings(c).signal.combineWith(builds(c).signal, filter.signal).map {
                case (Deferred.Error(e), _, _)                                  => Seq(span(e.stackTraceAsString))
                case (_, Deferred.Error(e), _)                                  => Seq(span(e.stackTraceAsString))
                case (Deferred.Success(missings), Deferred.Success(builds), kw) =>
                  val missingSet = missings.toSet
                  builds.values
                    .to(ArraySeq)
                    .filter { build =>
                      if (kw.isBlank) true
                      else build.hash.contains(kw) || build.isoDate.contains(kw) || build.version.contains(kw)
                    }
                    .sortBy(build => build.date -> build.version)(using Ordering[(Instant, String)].reverse)
                    .map { build =>
                      val selected = sig.map(_.build.contains(build.fmtNoArch))
                      val expected = archs.map(build.fmtWithArch(_)).toSet
                      a(
                        missingSet.intersect(expected) match {
                          case ms if ms.isEmpty     => navigateTo(Index(Some(build.fmtNoArch)))
                          case ms if ms == expected => cls := "missing-row"         // all missing
                          case _                    => cls := "missing-partial-row" // partial missing
                        },
                        cls("highlight-row is-active") <-- selected,
                        cls      := "panel-block",
                        nameAttr := build.fmtNoArch,
                        span(cls := "panel-icon", i(cls := "fas fa-file-archive ", dataAttr("aria-hidden") := "true")),
                        fontFamily := "monospace",
                        s"[${build.shortHash}]",
                        span(cls := "tag is-info", s"${build.isoDate}"),
                        nbsp,
                        span(cls := "tag is-primary", s"${build.version}"),
                        nbsp,
                        span(cls := "tag is-success", s"+${build.changes.size}")
                      )
                    } :+ div(
                    onMountCallback { ctx =>
                      for {
                        key     <- sig.observe(using ctx.owner).now().build
                        element <- Option(ctx.thisNode.ref.parentElement.querySelector(s"""[name="$key"]"""))
                      } {
                        element.scrollIntoView()
                        lut.signal.foreach(_.get(key).foreach { case (_, c) => compiler.set(c) })(using ctx.owner)
                      }
                    }
                  )
                case _ =>
                  Seq(
                    div(
                      display.flex,
                      alignContent.center,
                      justifyContent.center,
                      flexDirection.column,
                      button(cls := "button is-loading is-white is-large")
                    )
                  )
              }
            )
          }
        )

        val repo = (window.location.hostname, window.location.pathname) match {
          case (s"$owner.github.io", s"/$repo/") => s"$owner/$repo"
          case _                                 => "UNKNOWN"
        }

        val selectedBuild = articleTag(
          cls            := "message is-info",
          height.percent := 100,
          div(
            cls := "message-body",
            overflow.hidden,
            height.percent := 100,
            child <-- sig.combineWith(lut.signal).map {
              case (Index(None), _)      => span("Select a build for details")
              case (Index(Some(x)), lut) =>
                lut.get(x) match {
                  case None if lut.isEmpty     => span(s"Loading")
                  case None                    => span(s"Build \"$x\" not found")
                  case Some((build, compiler)) =>
                    div(
                      overflow.hidden,
                      height.percent := 100,
                      table(
                        cls             := "table is-narrow is-fullwidth",
                        backgroundColor := "transparent",
                        thead(),
                        tbody(
                          tr(td("Version"), td(build.version, fontFamily := "monospace")),
                          tr(td("Commit"), td(build.hash, fontFamily := "monospace")),
                          tr(
                            td("Date"),
                            td(
                              build.isoDate,
                              fontFamily := "monospace"
                            )
                          ),
                          tr(
                            td("Binaries"),
                            td(
                              archs.map { arch =>
                                val key = build.fmtWithArch(arch)
                                p(
                                  a(
                                    s"$key.squashfs",
                                    href := s"https://github.com/$repo/releases/download/$key/$key.squashfs"
                                  )
                                )
                              }
                            )
                          )
                        )
                      ),
                      div(
                        cls := "content is-small",
                        overflow.scroll,
                        height.percent := 100,
                        ul(build.changes.map { case (hash, date, message) =>
                          li(
                            a(
                              s"[$hash]",
                              fontFamily := "monospace",
                              href       := s"https://github.com/${compiler.repo}/commit/$hash",
                              target     := "_blank"
                            ),
                            " ",
                            span(
                              date.atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ISO_DATE),
                              fontFamily := "monospace"
                            ),
                            " ",
                            message
                          )
                        })
                      )
                    )
                }
            }
          )
        )

        div(
          cls := "container",
          display.flex,
          flexDirection.column,
          alignItems.stretch,
          height.percent := 100,
          a(
            href := "/",
            h1(
              cls := "title",
              textAlign.center,
              marginBottom.px := 8,
              span(cls := "icon", i(cls := "fas fa-cookie-bite"), margin.px := 16),
              "Compiler snapshots"
            )
          ),
          div(
            cls := "notification",
            strong(
              p(
                "This repo/static site contains GCC and LLVM snapshot builds spaced one week apart using the ISO8601 week-based-year;" +
                  " commits that fail to generate a build are excluded."
              )
            ),
            p(
              cls := "extra-intro",
              "Builds are compiled in CentOS 7 with ",
              a("glibc 2.17", href := "https://sourceware.org/glibc/wiki/Glibc%20Timeline"),
              ", most distros released after 2012 should be able to just download, untar, and use as-is without any external dependencies",
              br(),
              "APIs for listing all snapshots, build scripts, and Dockerfile for generating the snapshots are available ",
              a("in the repo", href := s"https://github.com/$repo/"),
              "."
            )
          ),
          div(
            cls             := "columns",
            flexGrow        := 1,
            marginBottom.px := 10,
            overflow.hidden,
            div(
              cls := "column is-one-third",
              cls("is-hidden-mobile") <-- sig.map(_.build.isDefined),
              height.percent := 100,
              buildSelection
            ),
            div(cls := "column is-full-mobile", height.percent := 100, selectedBuild)
          )
        )
      }

    render(
      dom.document.querySelector("body"),
      div(
        position.absolute,
        top    := "0",
        left   := "0",
        bottom := "0",
        right  := "0",
        child <-- pageSplitter.signal
      )
    ): Unit
  }
}
