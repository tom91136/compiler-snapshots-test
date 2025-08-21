package uob_hpc.snapshots

import scala.concurrent.ExecutionContext.Implicits.global
import scala.concurrent.Future
import scala.scalajs.js

import com.raquo.airstream.state.Var
import org.scalajs.dom.fetch

extension (inline t: Throwable) {
  inline def stackTraceAsString: String = {
    val sw = java.io.StringWriter()
    t.printStackTrace(java.io.PrintWriter(sw))
    sw.toString
  }
}

enum Deferred[+A] {
  case Pending
  case Success(a: A)
  case Error(e: Throwable)
}

given [A: upickle.default.ReadWriter]: upickle.default.ReadWriter[Var[A]] =
  upickle.default.readwriter[A].bimap[Var[A]](_.now(), Var(_))

inline def fetchRaw(inline url: String): Future[String]                = fetch(url).toFuture.flatMap(_.text().toFuture)
inline def fetchJson[A: Pickler.Reader](inline url: String): Future[A] = fetchRaw(url).map(Pickler.web.read[A](_))
