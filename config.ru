require_relative "src/rag"
require_relative "web/app"
require_relative "web/worker"

begin
  sys = Rag.build
rescue Rag::ConfigError => e
  abort e.message
end

Web.set :ask, sys.ask
Web.set :store, sys.store
Web.set :worker, Worker.new { |path| sys.ingest.call(path) }
Web.set :documents_dir, sys.config.documents_dir
run Web
