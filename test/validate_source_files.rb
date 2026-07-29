# frozen_string_literal: true

require 'erb'
require 'open3'
require 'rbconfig'
require 'yaml'

ROOT = File.expand_path('..', __dir__)

def run!(*command)
  stdout, stderr, status = Open3.capture3(*command, chdir: ROOT)
  return if status.success?

  warn stdout unless stdout.empty?
  warn stderr unless stderr.empty?
  abort "失敗: #{command.join(' ')}"
end

tracked_files, status = Open3.capture2('git', 'ls-files', chdir: ROOT)
abort 'git ls-filesに失敗しました' unless status.success?
files = tracked_files.lines(chomp: true)

files.grep(/\.rb\z/).each do |path|
  run!(RbConfig.ruby, '-c', path)
end

files.grep(/\.ya?ml\z/).each do |path|
  YAML.parse_file(File.join(ROOT, path))
end

files.grep(/\.erb\z/).each do |path|
  source = ERB.new(File.read(File.join(ROOT, path)), trim_mode: '-').src
  RubyVM::InstructionSequence.compile(source, path)
end

shell_files = files.select do |path|
  File.file?(File.join(ROOT, path)) && File.open(File.join(ROOT, path), &:readline).match?(%r{\A#!.*\b(?:ba)?sh\b})
rescue EOFError
  false
end

shell_files.each do |path|
  shell = File.open(File.join(ROOT, path), &:readline).include?('bash') ? 'bash' : 'sh'
  run!(shell, '-n', path)
end
run!('shellcheck', '--severity=error', '--', *shell_files) unless shell_files.empty?

puts "OK: Ruby #{files.grep(/\.rb\z/).length} files"
puts "OK: YAML #{files.grep(/\.ya?ml\z/).length} files"
puts "OK: ERB #{files.grep(/\.erb\z/).length} files"
puts "OK: Shell #{shell_files.length} files"
