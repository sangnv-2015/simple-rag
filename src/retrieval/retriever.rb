module Rag
  class Retriever
    def initialize(embedder:, store:, k:)
      @embedder, @store, @k = embedder, store, k
    end

    # Array<Rag::Hit>
    def call(question)
      @store.search(@embedder.embed_query(question), @k)
    end
  end
end
