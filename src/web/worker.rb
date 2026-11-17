require_relative "../rag"

# One thread, one queue: jobs run strictly one at a time (LibreOffice shares one profile dir).
class Worker
  def initialize(&job)
    @job = job
    @queue = Queue.new
    @lock = Mutex.new
    @names = [] # queued and running, one entry per job
    @thread = Thread.new { loop { run(@queue.pop) } }
  end

  def enqueue(path)
    @lock.synchronize { @names << Rag::Text.nfc(File.basename(path)) }
    @queue << path
  end

  def pending = @lock.synchronize { @names.dup }

  private

  def run(path)
    @job.call(path)
  rescue Rag::Error => e
    warn "ingest failed: #{e.class}: #{e.message}"
  rescue StandardError => e
    warn "ingest failed: #{e.class}"
  ensure
    @lock.synchronize { @names.delete_at(@names.index(Rag::Text.nfc(File.basename(path)))) }
  end
end
