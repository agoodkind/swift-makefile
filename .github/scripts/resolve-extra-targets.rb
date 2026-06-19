#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "set"

BUILTIN_TARGETS = Set.new(%w[
  analyze
  audit
  build
  build-check
  check
  lint
  lint-complexity
  lint-deadcode
  lint-format
  lint-swiftlint
  swiftcheck-extra
  test
]).freeze

def parse_targets(raw, label)
  parsed = JSON.parse(raw)
  unless parsed.is_a?(Array)
    warn "#{label} must be a JSON array of strings"
    exit 1
  end

  parsed.filter_map do |item|
    unless item.is_a?(String)
      warn "#{label} must contain only strings"
      exit 1
    end

    value = item.strip
    next if value.empty?

    value
  end
rescue JSON::ParserError => error
  warn "#{label} must be a JSON array of strings: #{error.message}"
  exit 1
end

def append_output(name, value)
  output_path = ENV["GITHUB_OUTPUT"]
  return if output_path.nil? || output_path.empty?

  File.open(output_path, "a") do |handle|
    handle.puts("#{name}=#{value}")
  end
end

explicit_targets = parse_targets(ENV.fetch("EXTRA_TARGETS", "[]"), "EXTRA_TARGETS")
legacy_targets = parse_targets(ENV.fetch("LEGACY_TARGETS", "[]"), "LEGACY_TARGETS")

combined_targets = []
seen_targets = Set.new

(explicit_targets + legacy_targets).each do |target|
  next if BUILTIN_TARGETS.include?(target.downcase)
  next if seen_targets.include?(target)

  combined_targets << target
  seen_targets << target
end

targets_json = JSON.generate(combined_targets)
targets_shell = combined_targets.join(" ")

append_output("targets", targets_json)
append_output("targets_shell", targets_shell)
append_output("count", combined_targets.length.to_s)

puts("extra-targets: resolved #{targets_json}")
