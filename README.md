# Finance
[![Build Status](https://travis-ci.org/tubedude/finance-elixir.svg?branch=master)](https://travis-ci.org/tubedude/finance-elixir)[![Coverage Status](https://coveralls.io/repos/github/tubedude/finance-elixir/badge.svg?branch=master)](https://coveralls.io/github/tubedude/finance-elixir?branch=master)

A library to calculate Xirr through the bisection method using parallel processes.

## Installation

The package can be installed as:

  1. Add finance to your list of dependencies in `mix.exs`:

        def deps do
          [{:finance, git: "https://github.com/resuelve/finance-elixir.git"
            tag: "1.0"}]
        end

  2. Ensure finance is started before your application:

        def application do
          [applications: [:finance]]
        end

## Documentation

 The Documentation is available in [hexdocs.pm](http://hexdocs.pm/finance/0.0.1/extra-api-reference.html)
