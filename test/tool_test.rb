require "test_helper"
require "tmpdir"

class ToolTest < Minitest::Test
  class FetchUrlTool < ActiveHarness::Tool
    tool_scope :web
    tool_name "fetch_url"
    description "Fetch"
    param :url, "URL"
    param :kind, "Kind", enum: %w[a b], required: false
    param :limit, "Limit", type: :integer, required: false
    def perform(input); input[:url]; end
  end

  class OrderedTool < ActiveHarness::Tool
    tool_scope :test
    tool_name "ordered"
    param :n, "n"
    step(:first)  { |input| (@log ||= []) << :first }
    step(:double, transform: true) { |input| input.merge(n: input[:n] * 2) }
    step(:last)   { |input| (@log ||= []) << :last << input[:n] }
    def perform(input); [@log, input[:n]]; end
  end

  def test_names
    assert_equal "fetch_url", FetchUrlTool.tool_name
    assert_equal "web::fetch_url", FetchUrlTool.full_name
    assert_equal "web__fetch_url", FetchUrlTool.wire_name
  end

  def test_scope_and_name_are_required
    klass = Class.new(ActiveHarness::Tool)
    assert_raises(ArgumentError) { klass.full_name }
    klass.tool_scope :os
    assert_raises(ArgumentError) { klass.full_name } # the name is not derived from the class any more
    klass.tool_name "ls"
    assert_equal "os::ls", klass.full_name
  end

  def test_to_schema
    schema = FetchUrlTool.to_schema
    assert_equal "web__fetch_url", schema[:name]
    assert_equal "object", schema[:parameters][:type]
    assert_equal ["url"], schema[:parameters][:required]
    assert_equal({ type: "string", description: "Kind", enum: %w[a b] }, schema[:parameters][:properties]["kind"])
    assert_equal "integer", schema[:parameters][:properties]["limit"][:type]
  end

  def test_validate_input
    assert_nil FetchUrlTool.validate_input(url: "x")
    assert_match(/missing required argument: url/, FetchUrlTool.validate_input({}))
    assert_match(/unknown argument: z/, FetchUrlTool.validate_input(url: "x", z: 1))
    assert_match(/invalid value for kind/, FetchUrlTool.validate_input(url: "x", kind: "c"))
    assert_match(/must be an object/, FetchUrlTool.validate_input("str"))
  end

  def test_ok_result
    r = EchoTool.call(input: { text: "hi" })
    assert_equal :ok, r.status
    assert_equal "echo: hi", r.output
    assert_equal "echo: hi", r.model_message
    assert_equal [:perform], r.steps.map(&:name)
    assert_nil r.failed_step
  end

  def test_steps_run_in_order_and_transform_replaces_payload
    r = OrderedTool.call(input: { n: 2 })
    assert_equal [[:first, :last, 4], 4], r.output
    assert_equal %i[first double last perform], r.steps.map(&:name)
  end

  def test_denied_has_safe_message_and_private_detail
    klass = Class.new(ActiveHarness::Tool) do
      tool_scope :test
      tool_name "anon1"
      param :path, "p"
      step(:guard) { |input| deny!("hidden dirs are off limits", detail: "segment .git in #{input[:path]}") }
      def perform(_); flunk("must not run"); end
    end
    r = klass.call(input: { path: "/x/.git" })
    assert_equal :denied, r.status
    assert_equal :guard, r.failed_step.name
    assert_equal "hidden dirs are off limits", r.model_message
    assert_match(/\.git/, r.failed_step.detail)
    assert_equal %i[guard], r.steps.map(&:name)
  end

  def test_unexpected_error_is_generic_for_the_model
    r = BoomTool.call(input: {})
    assert_equal :error, r.status
    assert_equal :perform, r.failed_step.name
    assert_equal ActiveHarness::Tool::GENERIC_ERROR_MESSAGE, r.model_message
    refute_match(/secret/, r.model_message)
    assert_match(/kaboom/, r.failed_step.detail)
    refute r.outcome_unknown
  end

  def test_unknown_outcome
    klass = Class.new(ActiveHarness::Tool) do
      tool_scope :test
      tool_name "anon2"
      def perform(_); unknown_outcome!("write timed out", detail: "after send"); end
    end
    r = klass.call(input: {})
    assert_equal :error, r.status
    assert r.outcome_unknown
    assert_equal ActiveHarness::Tool::UNKNOWN_OUTCOME_MESSAGE, r.model_message
    assert_equal "after send", r.failed_step.detail
  end

  def test_hooks
    log = []
    klass = Class.new(ActiveHarness::Tool) do
      tool_scope :test
      tool_name "anon3"
      step(:check) { |_| nil }
      on(:before_step)    { |name, _payload| log << [:before, name] }
      on(:after_step)     { |name, res| log << [:after, name, res.status] }
      on(:before_perform) { |payload| log << [:before_perform, payload] }
      on(:after_perform)  { |output| self.output = output.upcase }
      before(:step, :check) { |payload| log << [:per_step, payload] }
      def perform(_); "done"; end
    end
    r = klass.call(input: { a: 1 })
    assert_equal "DONE", r.output
    assert_includes log, [:per_step, { a: 1 }]
    assert_includes log, [:before_perform, { a: 1 }]
    assert_equal [:before, :check], log.first
  end

  def test_hook_can_deny
    klass = Class.new(ActiveHarness::Tool) do
      tool_scope :test
      tool_name "anon4"
      on(:before_perform) { |_| deny!("maintenance window") }
      def perform(_); flunk("must not run"); end
    end
    r = klass.call(input: {})
    assert_equal :denied, r.status
    assert_equal :perform, r.failed_step.name
    assert_equal "maintenance window", r.model_message
  end

  def test_subclass_inherits_steps_but_not_leaks_back
    parent = Class.new(ActiveHarness::Tool) { tool_scope :test; step(:a) { |_| nil }; def perform(_); 1; end }
    child  = Class.new(parent) { step(:b) { |_| nil } }
    assert_equal %i[a], parent.steps.map(&:name)
    assert_equal %i[a b], child.steps.map(&:name)
  end

  def test_context_reaches_the_tool
    klass = Class.new(ActiveHarness::Tool) do
      tool_scope :test
      tool_name "anon5"
      step(:admin_only) { |_| deny!("admins only") unless context[:admin] }
      def perform(_); "ok"; end
    end
    assert_equal :denied, klass.call(input: {}, context: { admin: false }).status
    assert_equal :ok,     klass.call(input: {}, context: { admin: true }).status
  end

  def test_path_policy
    Dir.mktmpdir do |dir|
      root    = File.realpath(dir)
      outside = Dir.mktmpdir
      File.write(File.join(root, "a.txt"), "x")
      File.symlink(outside, File.join(root, "escape"))

      klass = Class.new(ActiveHarness::Tool) do
        include ActiveHarness::Tool::PathPolicy
        tool_scope :os
        tool_name "anon6"
        param :path, "p"
        const_set(:ALLOWED_PATHS, [root].freeze)
        step(:resolve, transform: true) { |input| input.merge(path: safe_path!(input[:path])) }
        def perform(input); input[:path]; end
      end

      assert_equal File.join(root, "a.txt"), klass.call(input: { path: File.join(root, "a.txt") }).output
      assert_equal :denied, klass.call(input: { path: File.join(root, "..", "etc") }).status
      assert_equal :denied, klass.call(input: { path: File.join(root, "escape") }).status
      assert_equal :denied, klass.call(input: { path: root + "-sibling" }).status
      assert_equal :denied, klass.call(input: { path: "/definitely/missing" }).status
      assert_equal :denied, klass.call(input: { path: "a\0b" }).status
    end
  end
end
