module Rag
  class Embedder
    BATCH = 32

    def initialize(pipe: nil)
      if pipe.nil?
        require "informers" # lazy: unit tests never load the model
        pipe = Informers.pipeline("embedding", Rag::EMBED_MODEL, dtype: "q8")
      end
      @pipe = pipe
      @mutex = Mutex.new
    end

    def embed_passages(texts)
      texts.each_slice(BATCH).flat_map { |batch| run(batch.map { |t| "passage: #{t}" }) }
    end

    def embed_query(text)
      run(["query: #{text}"]).first
    end

    private

    def run(inputs)
      @mutex.synchronize { @pipe.call(inputs) }
    end
  end
end
