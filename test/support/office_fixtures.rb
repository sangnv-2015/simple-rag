require "open3"
require "tmpdir"
require "fileutils"

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
                                "-env:UserInstallation=file:///tmp/lo-profile",
                                "--convert-to", ext, "--outdir", DIR, File.join(DIR, "#{base}.txt"))
      raise "soffice failed: #{out}" unless st.success?
      File.join(DIR, "#{base}.#{ext}")
    end
  end
end
