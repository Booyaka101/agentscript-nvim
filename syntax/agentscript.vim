" Fallback syntax highlighting for Salesforce Agent Script (.agent).
" Keeps files readable when no Tree-sitter parser or LSP semantic tokens are
" active. Keywords taken from real upstream examples (salesforce/agentscript).

if exists('b:current_syntax')
  finish
endif

" Top-level / structural blocks
syn keyword agentscriptBlock config system variables language topic connections actions
syn keyword agentscriptBlock start_agent reasoning before_reasoning after_reasoning
syn keyword agentscriptField description instructions messages welcome error agent_name default_agent_user default_locale

" Procedural keywords
syn keyword agentscriptKeyword set run with transition if else
syn keyword agentscriptModifier mutable

" Primitive types
syn keyword agentscriptType string number boolean object list

" Literals
syn keyword agentscriptBoolean True False true false
syn match agentscriptNumber "\<\d\+\%(\.\d\+\)\=\>"
syn region agentscriptString start=+"+ skip=+\\"+ end=+"+ oneline

" References like @variables.user_city / @actions.get_weather
syn match agentscriptRef "@[A-Za-z_][A-Za-z0-9_.]*"

" Multiline template markers:  ->  and leading |
syn match agentscriptOperator "->"
syn match agentscriptTemplate "^\s*|.*$" contains=agentscriptRef

" Comments (also the # @dialect: header)
syn match agentscriptComment "#.*$" contains=agentscriptDialect,@Spell
syn match agentscriptDialect "@dialect:\s*\S\+" contained

hi def link agentscriptBlock     Keyword
hi def link agentscriptField     Identifier
hi def link agentscriptKeyword   Statement
hi def link agentscriptModifier  StorageClass
hi def link agentscriptType      Type
hi def link agentscriptBoolean   Boolean
hi def link agentscriptNumber    Number
hi def link agentscriptString    String
hi def link agentscriptRef       Special
hi def link agentscriptOperator  Operator
hi def link agentscriptTemplate  String
hi def link agentscriptComment   Comment
hi def link agentscriptDialect   SpecialComment

let b:current_syntax = 'agentscript'
