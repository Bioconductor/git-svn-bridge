require "test-unit"
require "test/unit"
require_relative "../app/core"
include GSBCore
require 'yaml'

ENV['TESTING_GSB'] = 'true'


Test::Unit.at_start do
    ENV['TESTING_GSB'] = 'true'
end

Test::Unit.at_exit do
end


class TestNewBridge < Test::Unit::TestCase

    $config = YAML.load_file("#{APP_ROOT}/etc/config.yml")


    def setup
    end

    def teardown
    end

    def cleanup
        # puts "\nin cleanup"
    end

    def test_sanity_checks
        assert_nothing_raised do
            GSBCore.bridge_sanity_checks("https://github.com/Bioconductor/RGalaxy", 
                "https://hedgehog.fhcrc.org/bioconductor/trunk/madman/Rpacks/RGalaxy",
                "git-wins", $config['test_username'], $config['test_password'])
        end
        
    end

end

