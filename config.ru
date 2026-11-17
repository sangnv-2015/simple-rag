require_relative "lib/rag"
require_relative "web/app"

begin
  sys = Rag.build
rescue Rag::ConfigError => e
  abort e.message
end

Web.set :ask, sys.ask
Web.set :store, sys.store
Web.set :documents_dir, sys.config.documents_dir
run Web
