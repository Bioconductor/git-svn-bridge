#require "test/unit"
require "test-unit"
require "test/unit"
#require 'minitest/unit'

Test::Unit.at_start do
  puts "in at_start"
end

Test::Unit.at_exit do
  puts "in at_exit"
end


class MyTest < Test::Unit::TestCase
    class << self
        def startup
            puts 'runs only once at start'
        end
        def shutdown
            puts 'runs only once at end'
        end
        # def suite
        #     mysuite = super
        #     def mysuite.run(*args)
        #       MyTest.startup()
        #       super
        #       MyTest.shutdown()
        #     end
        #     mysuite
        # end
    end

    def setup
        puts 'runs before each test'
    end
    def teardown
        puts 'runs after each test'
    end 
    def test_stuff
        assert(true)
    end
end