require 'origen_testers/smartest_based_tester/base/processors'
module OrigenTesters
  module SmartestBasedTester
    class Base
      class Flow < ATP::Formatter
        include OrigenTesters::Flow

        attr_accessor :test_suites, :test_methods, :lines, :stack, :var_filename

        def var_filename
          @var_filename || 'global'
        end

        def subdirectory
          'testflow/mfh.testflow.group'
        end

        def filename
          super.gsub('_flow', '')
        end

        def hardware_bin_descriptions
          @hardware_bin_descriptions ||= {}
        end

        def flow_control_variables
          Origen.interface.variables_file(self).flow_control_variables
        end

        def runtime_control_variables
          Origen.interface.variables_file(self).runtime_control_variables
        end

        def at_flow_start
        end

        def at_flow_end
        end

        def finalize(options = {})
          super
          test_suites.finalize
          test_methods.finalize
          @indent = 0
          @lines = []
          @stack = { on_fail: [], on_pass: [] }
          m = Processors::IfRanCleaner.new.process(model.ast)
          m = Processors::EmptyBranchCleaner.new.process(m)
          m = Processors::FlagOptimizer.new.process(m)
          process(m)
        end

        def line(str)
          @lines << (' ' * @indent * 2) + str
        end

        # def on_flow(node)
        #  line '{'
        #  @indent += 1
        #  process_all(node.children)
        #  @indent -= 1
        #  line "}, open,\"#{unique_group_name(node.find(:name).value)}\", \"\""
        # end

        def on_test(node)
          name = node.find(:object).to_a[0]
          name = name.name unless name.is_a?(String)
          if node.children.any? { |n| t = n.try(:type); t == :on_fail || t == :on_pass } ||
             !stack[:on_pass].empty? || !stack[:on_fail].empty?
            line "run_and_branch(#{name})"
            process_all(node.to_a.reject { |n| t = n.try(:type); t == :on_fail || t == :on_pass })
            line 'then'
            line '{'
            @indent += 1
            on_pass = node.children.find { |n| n.try(:type) == :on_pass }
            process_all(on_pass) if on_pass
            stack[:on_pass].each { |n| process_all(n) }
            @indent -= 1
            line '}'
            line 'else'
            line '{'
            @indent += 1
            on_fail = node.children.find { |n| n.try(:type) == :on_fail }
            with_continue(on_fail ? on_fail.children.any? { |n| n.try(:type) == :continue } : false) do
              process_all(on_fail) if on_fail
              stack[:on_fail].each { |n| process_all(n) }
            end
            @indent -= 1
            line '}'
          else
            line "run(#{name});"
          end
        end

        def on_render(node)
          node.to_a[0].split("\n").each do |l|
            line(l)
          end
        end

        def on_job(node)
          jobs, state, *nodes = *node
          jobs = clean_job(jobs)
          runtime_control_variables << ['JOB', '']
          condition = jobs.join(' or ')
          line "if #{condition} then"
          line '{'
          @indent += 1
          process_all(node) if state
          @indent -= 1
          line '}'
          line 'else'
          line '{'
          @indent += 1
          process_all(node) unless state
          @indent -= 1
          line '}'
        end

        def on_condition_flag(node)
          flag, state, *nodes = *node
          if flag.is_a?(Array)
            condition = flag.map { |f| "@#{f.upcase} == 1" }.join(' or ')
          else
            condition = "@#{flag.upcase} == 1"
          end
          line "if #{condition} then"
          line '{'
          @indent += 1
          process_all(nodes) if state
          @indent -= 1
          line '}'
          line 'else'
          line '{'
          @indent += 1
          process_all(nodes) unless state
          @indent -= 1
          line '}'
        end

        def on_flow_flag(node)
          flag, state, *nodes = *node
          [flag].flatten.each do |f|
            flow_control_variables << f.upcase
          end
          on_condition_flag(node)
        end

        def on_run_flag(node)
          flag, state, *nodes = *node
          [flag].flatten.each do |f|
            runtime_control_variables << f.upcase
          end
          on_condition_flag(node)
        end

        def on_enable_flow_flag(node)
          flag = node.value.upcase
          flow_control_variables << flag
          line "@#{flag} = 1;"
        end

        def on_disable_flow_flag(node)
          flag = node.value.upcase
          flow_control_variables << flag
          line "@#{flag} = 0;"
        end

        def on_set_run_flag(node)
          flag = node.value.upcase
          runtime_control_variables << flag
          line "@#{flag} = 1;"
        end

        def on_group(node)
          on_fail = node.children.find { |n| n.try(:type) == :on_fail }
          on_pass = node.children.find { |n| n.try(:type) == :on_pass }
          with_continue(on_fail && on_fail.children.any? { |n| n.try(:type) == :continue }) do
            line '{'
            @indent += 1
            stack[:on_fail] << on_fail if on_fail
            stack[:on_pass] << on_pass if on_pass
            process_all(node.children - [on_fail, on_pass])
            stack[:on_fail].pop if on_fail
            stack[:on_pass].pop if on_pass
            @indent -= 1
            line "}, open,\"#{unique_group_name(node.find(:name).value)}\", \"\""
          end
        end

        def on_set_result(node)
          unless @continue
            bin = node.find(:bin).try(:value)
            desc = node.find(:bin).to_a[1]
            sbin = node.find(:softbin).try(:value)
            sdesc = node.find(:softbin).to_a[1] || 'fail'
            if bin && desc
              hardware_bin_descriptions[bin] ||= desc
            end

            if node.to_a[0] == 'pass'
              line "stop_bin \"#{sbin}\", \"\", , good, noreprobe, green, #{bin}, over_on;"
            else
              line "stop_bin \"#{sbin}\", \"#{sdesc}\", , bad, noreprobe, red, #{bin}, over_on;"
            end
          end
        end

        def on_log(node)
          line "print_dl(\"#{node.to_a[0]}\");"
        end

        def unique_group_name(name)
          @group_names ||= {}
          if @group_names[name]
            @group_names[name] += 1
            "#{name}_#{@group_names[name]}"
          else
            @group_names[name] = 1
            name
          end
        end

        def clean_job(job)
          [job].flatten.map { |j| "@JOB == \"#{j.to_s.upcase}\"" }
        end

        def with_continue(value)
          orig = @continue
          @continue = true if value
          yield
          @continue = orig
        end
      end
    end
  end
end
