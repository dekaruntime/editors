; Forked from the tree-sitter-javascript, tree-sitter-typescript (tsx
; dialect), and tree-sitter-phpx query styles, extended for DekaScript.

; Variables
;----------

(identifier) @variable

(property_identifier) @property

; Types
;------

(type_identifier) @type

(predefined_type) @type.builtin

(union_type "|" @operator)

(option_type "?" @operator)

((identifier) @type
 (#match? @type "^[A-Z]"))

; Properties
;-----------

(pair
  key: (property_identifier) @property)

; DekaScript declarations
;------------------------

(fn_declaration
  name: (identifier) @function)

(receiver_method_declaration
  receiver_type: (type_identifier) @type
  name: (identifier) @function.method)

(fn_expression
  (formal_parameters
    (required_parameter
      pattern: (identifier) @variable.parameter)))

(struct_declaration
  name: (type_identifier) @type)

(struct_field
  name: (property_identifier) @property
  type: (_) @type)

(struct_embed
  (type_identifier) @type)

(enum_declaration
  name: (type_identifier) @type)

(enum_case
  name: (identifier) @constant)

(interface_declaration
  name: (type_identifier) @type)

(interface_field
  name: (property_identifier) @property
  type: (_) @type)

(interface_method_signature
  name: (property_identifier) @function.method)

(type_alias_declaration
  name: (type_identifier) @type.definition)

; DekaScript expressions
;-----------------------

(match_expression
  "match" @keyword)

(match_arm
  "=>" @operator)

(wildcard_pattern) @variable.builtin

(constructor_pattern
  name: (identifier) @constructor)

(struct_pattern
  name: (identifier) @type
  field: (identifier) @property)

(unsafe_expression
  "unsafe" @keyword
  (type_arguments (_) @type)?)

(raw_js) @embedded

(build_expression
  "build" @keyword)

(bridge_expression
  kind: (identifier) @module
  action: (identifier) @function.method)

(struct_literal
  name: (identifier) @type
  field: (identifier) @property)

(unwrap_expression
  ["unwrap" "or"] @keyword.function)

(none) @constant.builtin

; Function and method definitions
;--------------------------------

(function_expression
  name: (identifier) @function)

(function_declaration
  name: (identifier) @function)

(method_definition
  name: (property_identifier) @function.method)

(pair
  key: (property_identifier) @function.method
  value: [(function_expression) (arrow_function)])

(assignment_expression
  left: (member_expression
    property: (property_identifier) @function.method)
  right: [(function_expression) (arrow_function)])

(variable_declarator
  name: (identifier) @function
  value: [(function_expression) (arrow_function) (fn_expression)])

(assignment_expression
  left: (identifier) @function
  right: [(function_expression) (arrow_function)])

; Function and method calls
;--------------------------

(call_expression
  function: (identifier) @function)

(call_expression
  function: (member_expression
    property: (property_identifier) @function.method))

; Special identifiers
;--------------------

((identifier) @constructor
 (#match? @constructor "^[A-Z]"))

([
    (identifier)
    (shorthand_property_identifier)
    (shorthand_property_identifier_pattern)
 ] @constant
 (#match? @constant "^[A-Z_][A-Z\\d_]+$"))

((identifier) @variable.builtin
 (#match? @variable.builtin "^(arguments|module|console|window|document)$")
 (#is-not? local))

((identifier) @function.builtin
 (#eq? @function.builtin "require")
 (#is-not? local))

; Literals
;---------

(this) @variable.builtin
(super) @variable.builtin

[
  (true)
  (false)
  (null)
  (undefined)
  (none)
] @constant.builtin

(comment) @comment

[
  (string)
  (template_string)
] @string

(regex) @string.special
(number) @number

; Tokens
;-------

[
  ";"
  (optional_chain)
  "."
  ","
  ":"
] @punctuation.delimiter

[
  "--"
  "-"
  "-="
  "!="
  "!=="
  "*"
  "**"
  "*="
  "/"
  "/="
  "&&="
  "??="
  "%"
  "%="
  "^="
  "+"
  "++"
  "+="
  "<"
  "<="
  "="
  "=="
  "==="
  "=>"
  ">"
  ">="
  ">>="
  ">>>="
  "<<="
  "|"
  "|>"
  "||"
  "||="
  "?"
  "?."
] @operator

[
  (escape_sequence)
] @escape

[
  (template_substitution)
  "${"
  "}"
] @punctuation.special

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

(type_arguments
  ["<" ">"] @punctuation.bracket)

(type_parameters
  ["<" ">"] @punctuation.bracket)

; Keywords
;---------

[
  "alias"
  "as"
  "async"
  "await"
  "break"
  "bridge"
  "build"
  "const"
  "continue"
  "else"
  "enum"
  "export"
  "fn"
  "for"
  "from"
  "if"
  "import"
  "interface"
  "let"
  "match"
  "mut"
  "of"
  "return"
  "struct"
  "super"
  "type"
  "unsafe"
] @keyword
