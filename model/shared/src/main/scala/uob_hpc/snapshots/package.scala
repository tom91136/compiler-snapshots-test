package uob_hpc.snapshots

import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import scala.collection.immutable.ArraySeq
import scala.reflect.ClassTag

import Pickler.*

def timed[R](block: => R): (R, Double) = {
  val t0     = System.nanoTime()
  val result = block
  val t1     = System.nanoTime()
  result -> ((t1 - t0).toDouble / 1e9)
}

def timed[R](name: String)(block: => R): R = {
  val (r, elapsed) = timed(block)
  println(s"[$name] ${elapsed}s")
  r
}

// XXX GH release has a hard 125000 char limit in the body
case class Build(
    version: String,
    date: Instant,
    hash: String,
    hashLength: Int,
    changes: ArraySeq[(String, Instant, String)]
) derives ReadWriter {
  def shortHash: String    = hash.substring(0, hashLength)
  lazy val isoDate: String = date.atOffset(ZoneOffset.UTC).format(DateTimeFormatter.ISO_DATE)
}
