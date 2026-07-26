#!/usr/bin/env ruby

require "yaml"

workflow_path = ARGV.fetch(0)
workflow = YAML.load_file(workflow_path)
repository_root = File.dirname(File.dirname(File.dirname(workflow_path)))
triggers = workflow["on"]
if triggers.nil?
    triggers = workflow.fetch(true)
end

def require_value(actual, expected, label)
    return if actual == expected

    abort "release workflow contract: #{label} was #{actual.inspect}, expected #{expected.inspect}"
end

def find_step(steps, name)
    steps.find { |step| step["name"] == name }
end

expected_outputs = [
    "release-tag",
    "release-track",
    "source-sha",
    "artifact-version",
    "build-version",
    "marketing-version",
]
actual_outputs = triggers.dig("workflow_call", "outputs").keys.sort
require_value(actual_outputs, expected_outputs.sort, "reusable workflow outputs")
require_value(workflow.dig("concurrency", "group"), "release-${{ github.repository }}", "concurrency group")
require_value(workflow.dig("concurrency", "cancel-in-progress"), false, "concurrency cancellation")

source_job = workflow.dig("jobs", "source")
source_step = find_step(source_job.fetch("steps"), "Resolve source")
require_value(source_step.fetch("run"), "bash scripts/release-source.sh", "source resolver")

build_job = workflow.dig("jobs", "build")
build_checkout = build_job.fetch("steps").find { |step| step["uses"] == "actions/checkout@v7" }
require_value(build_checkout.dig("with", "ref"), "${{ needs.meta.outputs.source_sha }}", "build source checkout")

publish_job = workflow.dig("jobs", "publish")
publish_checkout = publish_job.fetch("steps").find { |step| step["uses"] == "actions/checkout@v7" }
require_value(publish_checkout.dig("with", "ref"), "${{ needs.meta.outputs.source_sha }}", "publish source checkout")
publish_step = find_step(publish_job.fetch("steps"), "Publish release")
require_value(publish_step.dig("env", "RELEASE_SOURCE_SHA"), "${{ needs.meta.outputs.source_sha }}", "publish source SHA")
require_value(publish_step.dig("env", "RELEASE_TRACK"), "${{ needs.meta.outputs.release_track }}", "publish release track")

caller_path = File.join(repository_root, ".github/workflows/release.yml")
caller = YAML.load_file(caller_path)
caller_triggers = caller["on"] || caller.fetch(true)
dispatch_inputs = caller_triggers.dig("workflow_dispatch", "inputs")
expected_dispatch_inputs = [
    "allow-source-sha",
    "candidate-asset-pattern",
    "candidate-tag",
    "source-sha",
]
require_value(dispatch_inputs.keys.sort, expected_dispatch_inputs.sort, "stable promotion inputs")
release_job = caller.dig("jobs", "release")
require_value(
    release_job.dig("with", "release-track"),
    "${{ github.event_name == 'workflow_dispatch' && 'stable' || 'prerelease' }}",
    "caller release track selection",
)

release_makefile_path = File.join(repository_root, "swift-release.mk")
release_makefile = File.read(release_makefile_path)
abort "release workflow contract: pre-release publishing flag is missing" unless
  release_makefile.include?("prerelease_arg=\"--prerelease\"")
abort "release workflow contract: publish source SHA is missing" unless
  release_makefile.include?("RELEASE_SOURCE_SHA:-$${GITHUB_SHA")
