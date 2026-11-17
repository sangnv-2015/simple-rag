require_relative "src/rag"
require_relative "src/web/app"
require_relative "src/web/worker"

begin
  sys = Rag.build
rescue Rag::ConfigError => e
  abort e.message
end

Web.set :ask, sys.ask
Web.set :store, sys.store
Web.set :worker, Worker.new { |id, path| sys.ingest.run(id, path) }
Web.set :ingest, sys.ingest
Web.set :retriever, sys.retriever
Web.set :documents_dir, sys.config.documents_dir
run Web
