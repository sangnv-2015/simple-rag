require "securerandom"

module Rag
  # Trust boundary: filename and body come straight from the browser.
  module Upload
    class Rejected < Rag::Error; end

    EXTENSIONS = %w[pdf docx].freeze
    CHUNK = 64 * 1024

    def self.sanitize(filename)
      name = Text.nfc(filename.to_s.dup.force_encoding(Encoding::UTF_8).scrub("_"))
      name = name.tr("\\", "/").rpartition("/").last
      name = name.gsub(/[[:cntrl:]]/, "").gsub(/[^\p{L}\p{N}._ ()-]/, "_").sub(/\A[. ]+/, "")
      stem, dot, ext = name.rpartition(".")
      ext = ext.downcase
      raise Rejected, "Chỉ nhận file .pdf và .docx." if stem.empty? || dot.empty? || !EXTENSIONS.include?(ext)

      stem = stem[0, 100]
      stem = stem.chop while stem.bytesize > 200 # filesystem name limit is 255 bytes
      "#{stem}.#{ext}"
    end

    def self.save(filename:, io:, dir:, max_bytes: Rag::MAX_UPLOAD_BYTES)
      name = sanitize(filename)
      root = File.realpath(dir)
      final = File.expand_path(name, root)
      raise Rejected, "Tên file không hợp lệ." unless final.start_with?(root + "/")
      raise Rejected, "Tên file không hợp lệ." if File.directory?(final) && !File.symlink?(final)

      # Not a .pdf/.docx name, so a crash leaves nothing ingest would pick up.
      tmp = File.join(root, ".upload-#{SecureRandom.hex(8)}.tmp")
      created = false
      begin
        total = 0
        # EXCL: never follow or truncate anything already at the temp name.
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
          created = true
          f.binmode
          while (chunk = io.read(CHUNK)) && !chunk.empty?
            total += chunk.bytesize
            raise Rejected, "File quá lớn (tối đa 30 MB)." if total > max_bytes

            f.write(chunk)
          end
        end
        begin
          File.rename(tmp, final)
        rescue SystemCallError
          raise Rejected, "Tên file không hợp lệ."
        end
      ensure
        File.delete(tmp) if created && File.exist?(tmp)
      end
      final
    end
  end
end
