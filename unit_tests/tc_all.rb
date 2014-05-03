# Run this file in order to run all unit tests.
# Each test file must be added manually below.

ENV['TESTING_GSB'] = 'true'
require_relative './tc_core'
require_relative './tc_resolve_diffs'
require_relative './tc_login'
