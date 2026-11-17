module Rag
  class Retriever
    def initialize(embedder:, store:, k:)
      @embedder, @store, @k = embedder, store, k
    end

    # Array<Rag::Hit>
    def call(question, tenant_id: Rag::DEFAULT_TENANT, document_ids: [], k: nil)
      @store.search(@embedder.embed_query(question), k || @k, tenant_id: tenant_id, document_ids: document_ids)
    end
  end
end
