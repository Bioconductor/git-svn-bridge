ENV['TESTING_GSB'] = 'true'
require "test-unit"
require "test/unit"
require_relative "../app/core"
include GSBCore

require 'yaml'

Test::Unit.at_start do
    $config = YAML.load_file("#{APP_ROOT}/etc/config.yml")
end



class TestLogin < Test::Unit::TestCase


    def test_login
        assert_nothing_raised do
            GSBCore.login($config['test_username'], $config['test_password'])
        end

        assert_raise(InvalidLogin) do 
            GSBCore.login("fweathering", "ibujnuxx")
        end

       assert_raise(InvalidLogin) do
           GSBCore.login("readonly", "readonly")
       end

    end

end