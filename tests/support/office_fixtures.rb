require "open3"
require "tmpdir"
require "fileutils"
require "zlib"

# Builds real .pdf/.docx files with LibreOffice, once per test run.
module OfficeFixtures
  DIR = Dir.mktmpdir("office-fixtures")
  Minitest.after_run { FileUtils.remove_entry(DIR) }

  def self.pdf(text) = build(text, "pdf")
  def self.docx(text) = build(text, "docx")

  def self.build(text, ext)
    (@built ||= {})[[text, ext]] ||= begin
      base = "f#{@built.size}"
      File.write(File.join(DIR, "#{base}.txt"), text)
      out, st = Open3.capture2e("timeout", "120", "soffice", "--headless",
                                "-env:UserInstallation=#{Rag::Extract.profile_url}",
                                "--convert-to", ext, "--outdir", DIR, File.join(DIR, "#{base}.txt"))
      raise "soffice failed: #{out}" unless st.success?
      File.join(DIR, "#{base}.#{ext}")
    end
  end

  W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  DML = "http://schemas.openxmlformats.org/drawingml/2006"

  # A real .docx whose body shows a linked (not embedded) picture fetched from `url`.
  # Built with a tiny stored-zip writer: the image has no zip CLI and there is no rubyzip gem.
  def self.docx_with_linked_image(url, text = "Tài liệu có ảnh liên kết ngoài")
    pkg = "http://schemas.openxmlformats.org/package/2006"
    doc = <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="#{W}" xmlns:r="#{REL}" xmlns:wp="#{DML}/wordprocessingDrawing" xmlns:a="#{DML}/main" xmlns:pic="#{DML}/picture"><w:body>
      <w:p><w:r><w:t>#{text}</w:t></w:r></w:p>
      <w:p><w:r><w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/><wp:docPr id="1" name="x"/><a:graphic><a:graphicData uri="#{DML}/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="x"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:link="rId9"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
      </w:body></w:document>
    XML
    files = {
      "[Content_Types].xml" => %(<?xml version="1.0"?><Types xmlns="#{pkg}/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>),
      "_rels/.rels" => %(<?xml version="1.0"?><Relationships xmlns="#{pkg}/relationships"><Relationship Id="rId1" Type="#{REL}/officeDocument" Target="word/document.xml"/></Relationships>),
      "word/document.xml" => doc,
      "word/_rels/document.xml.rels" => %(<?xml version="1.0"?><Relationships xmlns="#{pkg}/relationships"><Relationship Id="rId9" Type="#{REL}/image" Target="#{url}" TargetMode="External"/></Relationships>)
    }
    path = File.join(DIR, "linked-#{files.hash.abs}.docx")
    File.binwrite(path, stored_zip(files))
    path
  end

  def self.stored_zip(files)
    out = "".b
    central = "".b
    files.each do |name, data|
      data = data.b
      crc = Zlib.crc32(data)
      head = [20, 0, 0, 0, 0, crc, data.size, data.size, name.bytesize, 0].pack("vvvvvVVVvv")
      central << ["PK\x01\x02".b, [20].pack("v"), head, [0, 0, 0, 0, out.size].pack("vvvVV"), name.b].join
      out << "PK\x03\x04".b << head << name.b << data
    end
    offset = out.size
    out << central << "PK\x05\x06".b << [0, 0, files.size, files.size, central.size, offset, 0].pack("vvvvVVv")
  end
end
