require_relative "../rag"

# One thread, one queue: jobs run strictly one at a time (LibreOffice shares one profile dir).
class Worker
  def initialize(&job)
    @job = job
    @queue = Queue.new
    @lock = Mutex.new
    @keys = [] # queued and running, one entry per job
    @thread = Thread.new { loop { run(@queue.pop) } }
  end

  def enqueue(key, *args)
    @lock.synchronize { @keys << key }
    @queue << [key, args]
  end

  def pending = @lock.synchronize { @keys.dup }

  private

  def run((key, args))
    @job.call(key, *args)
  rescue Rag::Error => e
    warn "ingest failed: #{e.class}: #{e.message}"
  rescue StandardError => e
    warn "ingest failed: #{e.class}"
  ensure
    @lock.synchronize { @keys.delete_at(@keys.index(key)) }
  end
end
