require "test_helper"
require "timeout"
require_relative "../../src/web/worker"

class WorkerTest < Minitest::Test
  def wait_until
    Timeout.timeout(5) { sleep 0.01 until yield }
  end

  def test_jobs_run_one_at_a_time_in_order
    log = Queue.new
    gate = Queue.new
    w = Worker.new { |id, p| log << [:start, p]; gate.pop; log << [:end, p] }
    w.enqueue(1, "/d/a.pdf")
    w.enqueue(2, "/d/b.pdf")
    assert_equal [:start, "/d/a.pdf"], log.pop
    sleep 0.1
    assert_equal true, log.empty?, "second job must not start before the first is released"
    gate << 1
    assert_equal [:end, "/d/a.pdf"], log.pop
    assert_equal [:start, "/d/b.pdf"], log.pop
    gate << 1
    assert_equal [:end, "/d/b.pdf"], log.pop
  end

  def test_pending_lists_queued_and_running_keys_then_empties
    gate = Queue.new
    started = Queue.new
    w = Worker.new { |_, _| started << 1; gate.pop }
    w.enqueue(1, "/d/a.pdf")
    w.enqueue(2, "/d/b.pdf")
    started.pop
    assert_equal [1, 2], w.pending
    2.times { gate << 1 }
    wait_until { w.pending.empty? }
  end

  def test_failing_job_does_not_kill_worker
    done = Queue.new
    w = Worker.new { |_, p| raise Rag::Error, "boom" if p.end_with?("a.pdf"); done << p }
    _, err = capture_io { w.enqueue(1, "/d/a.pdf"); w.enqueue(2, "/d/b.pdf"); assert_equal "/d/b.pdf", done.pop; wait_until { w.pending.empty? } }
    assert_includes err, "Rag::Error: boom"
  end

  def test_non_rag_error_logs_class_only
    w = Worker.new { raise "secret detail" }
    _, err = capture_io { w.enqueue(1, "/d/a.pdf"); wait_until { w.pending.empty? } }
    assert_includes err, "RuntimeError"
    refute_includes err, "secret detail"
  end
end
