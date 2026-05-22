# Used by "mix format"
locals_without_parens = [
  method: 2,
  method: 3,
  field: 3,
  variant: 2,
  variant: 3,
  removed: 1,
  defconst: 3
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
