require "open3"
require "tmpdir"
require "fileutils"

module Rag
  module Extract
    class Error < Rag::Error; end

    def self.pages(path)
      path = File.expand_path(path)
      raise Error, "Không đọc được tệp #{File.basename(path)}." unless File.readable?(path)
      case File.extname(path).downcase
      when ".pdf" then pdf_pages(path)
      when ".docx"
        # soffice happily imports garbage as plain text, so check the zip magic first.
        raise Error, "Không đọc được tệp #{File.basename(path)}." unless File.binread(path, 2) == "PK"
        Dir.mktmpdir("rag-docx") do |dir|
          run("timeout", "120", "soffice", "--headless", "-env:UserInstallation=#{profile_url}",
              "--convert-to", "pdf", "--outdir", dir, path)
          converted = File.join(dir, "#{File.basename(path, '.*')}.pdf")
          raise Error, "Không chuyển được tệp #{File.basename(path)} sang PDF." unless File.exist?(converted)
          pdf_pages(converted, File.basename(path))
        end
      else
        raise Error, "Chỉ hỗ trợ tệp .pdf và .docx."
      end
    end

    # New directory name on purpose: an older profile may already hold a registrymodifications.xcu without these settings.
    PROFILE_DIR = "/tmp/lo-profile-safe".freeze
    # A hostile document can link remote images; without this LibreOffice fetches them while converting.
    PROFILE_SETTINGS = <<~XML.freeze
      <?xml version="1.0" encoding="UTF-8"?>
      <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value></prop></item>
      <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
      </oor:items>
    XML

    # The -env:UserInstallation value for every soffice run; seeds the locked-down profile first.
    def self.profile_url
      file = File.join(PROFILE_DIR, "user", "registrymodifications.xcu")
      unless File.exist?(file)
        FileUtils.mkdir_p(File.dirname(file))
        File.write("#{file}.#{Process.pid}", PROFILE_SETTINGS)
        File.rename("#{file}.#{Process.pid}", file)
      end
      "file://#{PROFILE_DIR}"
    end

    def self.split_pages(raw)
      chunks = raw.split("\f", -1)
      chunks.pop if chunks.last == ""
      chunks.each_with_index.map do |chunk, i|
        text = Text.clean(chunk)
        Page.new(number: i + 1, raw_text: text, markdown: nil, fallback: false,
                 readable: text.scan(/\p{L}/).size >= MIN_LETTERS)
      end
    end

    def self.pdf_pages(path, name = File.basename(path))
      out = run("timeout", "120", "pdftotext", "-layout", "-l", (MAX_PAGES + 1).to_s, path, "-", name: name)
      split_pages(out.force_encoding("UTF-8").scrub(""))
    end

    # Messages are shown to users: never include command output or paths.
    def self.run(*cmd, name: nil)
      out, err, st = Open3.capture3(*cmd)
      return out if st.success?
      tool = cmd.find { |c| %w[pdftotext soffice].include?(c) }
      warn "extract: #{tool} exit #{st.exitstatus.inspect}: #{err.scrub("").strip[0, 300]}" # operator log only
      name ||= File.basename(cmd.last)
      raise Error, "Quá thời gian xử lý tệp #{name}." if st.exitstatus == 124
      raise Error, "Không đọc được tệp #{name}."
    end
    private_class_method :pdf_pages, :run
  end
end
