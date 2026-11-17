require "test_helper"

class SemanticChunkerTest < Minitest::Test
  TOPICS = %w[alpha beta gamma delta].freeze

  # One-hot per topic keyword: similarity 1 inside a topic, 0 across.
  def one_hot(texts)
    @calls = (@calls || 0) + 1
    texts.map { |t| TOPICS.map { |k| t.include?(k) ? 1.0 : 0.0 } }
  end

  def split(text, **o) = Rag::SemanticChunker.split(text, embed: ->(t) { one_hot(t) }, **o)

  def test_splits_at_topic_change
    text = "alpha one. alpha two. alpha three. beta one. beta two. beta three."
    assert_equal ["alpha one.\nalpha two.\nalpha three.", "beta one.\nbeta two.\nbeta three."], split(text)
  end

  def test_percentile_cuts_only_lowest_gaps
    # sims: 1, 0.5, 1, 1 -> only the 0.5 gap is below the 25th percentile
    vecs = [[1.0, 0.0], [1.0, 0.0], [1.0, 1.0], [1.0, 1.0], [1.0, 1.0]]
    text = "a one. a two. a three. a four. a five."
    chunks = Rag::SemanticChunker.split(text, embed: ->(_) { vecs }, percentile: 25, min_units: 5)
    assert_equal ["a one.\na two.", "a three.\na four.\na five."], chunks
  end

  def test_few_units_use_the_floor
    text = "alpha one. alpha two. alpha three."
    assert_equal 1, split(text, floor: 0.5).size
    assert_equal 3, split(text, floor: 1.1).size
  end

  def test_chunk_never_exceeds_max_chars
    text = (1..30).map { |i| "alpha sentence number #{i}." }.join(" ")
    chunks = split(text, max_chars: 100)
    assert_operator chunks.size, :>, 1
    assert(chunks.all? { |c| c.size <= 100 })
  end

  def test_table_is_one_unit_and_long_table_splits_by_rows
    table = "| a | b |\n|---|---|\n| alpha 1 | x |\n| alpha 2 | y |"
    assert_equal ["alpha before.\n\n#{table}"], split("alpha before.\n#{table}")
    rows = (1..40).map { |i| "| alpha #{i} | #{"z" * 20} |" }
    chunks = split(rows.join("\n"), max_chars: 200)
    assert_operator chunks.size, :>, 1
    assert(chunks.all? { |c| c.size <= 200 })
    assert_equal rows, chunks.flat_map { |c| c.split("\n") }
  end

  def test_heading_attaches_to_following_unit
    text = "alpha one.\n# Beta heading\nbeta one. beta two."
    chunks = split(text)
    assert_equal ["alpha one.", "# Beta heading\nbeta one.\n\nbeta two."], chunks
    assert_equal ["# Beta heading\nbeta one."], Rag::SemanticChunker.units("# Beta heading\nbeta one.")
  end

  def test_embed_called_once_per_page
    split("alpha one. beta one. gamma one.")
    assert_equal 1, @calls
  end

  def test_no_content_lost
    text = "alpha one. beta two! gamma three?\n# H\ndelta four.\n| t | u |\n| alpha | x |"
    out = Rag::Text.squash(split(text, max_chars: 30).join(" "))
    Rag::SemanticChunker.units(text).each { |u| assert_includes out, Rag::Text.squash(u) }
  end

  def test_degenerate_pages
    assert_equal [], split("")
    assert_equal [], split(" \n\t \n")
    assert_equal ["alpha only."], split("alpha only.")
    assert_equal ["# Alpha title"], split("# Alpha title")
    assert_equal ["| alpha | b |"], split("| alpha | b |")
    long = "x" * 5000
    chunks = split(long, max_chars: 1000)
    assert_operator chunks.size, :>, 1
    assert(chunks.all? { |c| c.size <= 1000 })
    same = split(Array.new(20, "alpha same.").join(" "))
    assert_equal 1, same.size
    assert_operator same.first.size, :<=, Rag::MAX_CHUNK_CHARS
  end
end
