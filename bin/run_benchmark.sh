#!/bin/bash
# Quick benchmark runner for pg_query qualify functions

set -e

echo "Building pg_query extension..."
bundle exec rake compile >/dev/null 2>&1

echo "Running qualify performance benchmark..."
echo ""

bundle exec ruby bin/benchmark_qualify.rb
