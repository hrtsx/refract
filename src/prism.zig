const c = @cImport({
    @cInclude("prism.h");
});

pub const Arena = c.pm_arena_t;
pub const Parser = c.pm_parser_t;
pub const Node = c.pm_node_t;
pub const NodeList = c.pm_node_list_t;
pub const NodeType = c.pm_node_type_t;
pub const Location = c.pm_location_t;

// Typed node structs (cast from *Node when type matches)
pub const ClassNode = c.pm_class_node_t;
pub const ModuleNode = c.pm_module_node_t;
pub const DefNode = c.pm_def_node_t;
pub const ConstReadNode = c.pm_constant_read_node_t;
pub const ConstWriteNode = c.pm_constant_write_node_t;
pub const CallNode = c.pm_call_node_t;
pub const ConstantPathNode = c.pm_constant_path_node_t;

// Parameter nodes
pub const ParametersNode = c.pm_parameters_node_t;
pub const RequiredParamNode = c.pm_required_parameter_node_t;
pub const OptionalParamNode = c.pm_optional_parameter_node_t;
pub const RestParamNode = c.pm_rest_parameter_node_t;
pub const RequiredKwParamNode = c.pm_required_keyword_parameter_node_t;
pub const OptionalKwParamNode = c.pm_optional_keyword_parameter_node_t;
pub const KeywordRestParamNode = c.pm_keyword_rest_parameter_node_t;
pub const BlockParamNode = c.pm_block_parameter_node_t;

// Assignment nodes
pub const LocalVarWriteNode = c.pm_local_variable_write_node_t;
pub const LocalVarReadNode = c.pm_local_variable_read_node_t;
pub const InstanceVarWriteNode = c.pm_instance_variable_write_node_t;
pub const ClassVarWriteNode = c.pm_class_variable_write_node_t;

// Symbol and arguments nodes
pub const SymbolNode = c.pm_symbol_node_t;
pub const StringNode = c.pm_string_node_t;
pub const ArgumentsNode = c.pm_arguments_node_t;

// Diagnostic types
pub const DiagnosticList = c.pm_list_t;
pub const DiagnosticNode = c.pm_list_node_t;
pub const Diagnostic = c.pm_diagnostic_t;

// Name/position resolution types
pub const ConstantId = c.pm_constant_id_t;
pub const Constant = c.pm_constant_t;
pub const ConstantPool = c.pm_constant_pool_t;
pub const LineOffsetList = c.pm_line_offset_list_t;
pub const LineColumn = c.pm_line_column_t;

pub const arena_free = c.pm_arena_free;
pub const parser_init = c.pm_parser_init;
pub const parser_free = c.pm_parser_free;
pub const parse = c.pm_parse;
pub const visit_node = c.pm_visit_node;
pub const visit_child_nodes = c.pm_visit_child_nodes;
pub const node_type_to_str = c.pm_node_type_to_str;
pub const constantPoolIdToConstant = c.pm_constant_pool_id_to_constant;
pub const lineOffsetListLineColumn = c.pm_line_offset_list_line_column;

// Node type constants for symbol extraction
pub const NODE_CLASS = c.PM_CLASS_NODE;
pub const NODE_MODULE = c.PM_MODULE_NODE;
pub const NODE_DEF = c.PM_DEF_NODE;
pub const NODE_CONSTANT = c.PM_CONSTANT_READ_NODE;
pub const NODE_CONSTANT_WRITE = c.PM_CONSTANT_WRITE_NODE;
pub const NODE_CONSTANT_PATH = c.PM_CONSTANT_PATH_NODE;
pub const NODE_CALL = c.PM_CALL_NODE;

// Parameter node type constants
pub const NODE_PARAMETERS = c.PM_PARAMETERS_NODE;
pub const NODE_REQUIRED_PARAM = c.PM_REQUIRED_PARAMETER_NODE;
pub const NODE_OPTIONAL_PARAM = c.PM_OPTIONAL_PARAMETER_NODE;
pub const NODE_REST_PARAM = c.PM_REST_PARAMETER_NODE;
pub const NODE_REQUIRED_KW_PARAM = c.PM_REQUIRED_KEYWORD_PARAMETER_NODE;
pub const NODE_OPTIONAL_KW_PARAM = c.PM_OPTIONAL_KEYWORD_PARAMETER_NODE;
pub const NODE_KEYWORD_REST_PARAM = c.PM_KEYWORD_REST_PARAMETER_NODE;
pub const NODE_BLOCK_PARAM = c.PM_BLOCK_PARAMETER_NODE;
pub const NODE_LOCAL_VAR_WRITE = c.PM_LOCAL_VARIABLE_WRITE_NODE;
pub const NODE_LOCAL_VAR_READ = c.PM_LOCAL_VARIABLE_READ_NODE;
pub const NODE_INSTANCE_VAR_WRITE = c.PM_INSTANCE_VARIABLE_WRITE_NODE;
pub const NODE_CLASS_VAR_WRITE = c.PM_CLASS_VARIABLE_WRITE_NODE;
pub const ConstantPathWriteNode = c.pm_constant_path_write_node_t;
pub const NODE_CONSTANT_PATH_WRITE = c.PM_CONSTANT_PATH_WRITE_NODE;

// Literal node type constants for AST inference
pub const NODE_INTEGER = c.PM_INTEGER_NODE;
pub const NODE_FLOAT = c.PM_FLOAT_NODE;
pub const NODE_STRING = c.PM_STRING_NODE;
pub const NODE_INTERPOLATED_STR = c.PM_INTERPOLATED_STRING_NODE;
pub const NODE_SYMBOL = c.PM_SYMBOL_NODE;
pub const NODE_TRUE = c.PM_TRUE_NODE;
pub const NODE_FALSE = c.PM_FALSE_NODE;
pub const NODE_NIL = c.PM_NIL_NODE;
pub const NODE_ARRAY = c.PM_ARRAY_NODE;
pub const NODE_HASH = c.PM_HASH_NODE;
pub const NODE_RANGE = c.PM_RANGE_NODE;
pub const NODE_STATEMENTS = c.PM_STATEMENTS_NODE;
pub const StatementsNode = c.pm_statements_node_t;
pub const NODE_ALIAS_METHOD = c.PM_ALIAS_METHOD_NODE;
pub const AliasMethodNode = c.pm_alias_method_node_t;
pub const NODE_SELF = c.PM_SELF_NODE;
pub const NODE_LAMBDA = c.PM_LAMBDA_NODE;
pub const LambdaNode = c.pm_lambda_node_t;
pub const BlockParametersNode = c.pm_block_parameters_node_t;
pub const NODE_BLOCK_PARAMETERS = c.PM_BLOCK_PARAMETERS_NODE;
pub const BlockNode = c.pm_block_node_t;
pub const NODE_BLOCK = c.PM_BLOCK_NODE;
pub const NODE_SINGLETON_CLASS = c.PM_SINGLETON_CLASS_NODE;
pub const SingletonClassNode = c.pm_singleton_class_node_t;
pub const HashNode = c.pm_hash_node_t;
pub const KeywordHashNode = c.pm_keyword_hash_node_t;
pub const AssocNode = c.pm_assoc_node_t;
pub const NODE_KEYWORD_HASH = c.PM_KEYWORD_HASH_NODE;
pub const NODE_ASSOC = c.PM_ASSOC_NODE;
pub const InstanceVarReadNode = c.pm_instance_variable_read_node_t;
pub const NODE_INSTANCE_VAR_READ = c.PM_INSTANCE_VARIABLE_READ_NODE;
pub const IfNode = c.pm_if_node_t;
pub const NODE_IF = c.PM_IF_NODE;
pub const ElseNode = c.pm_else_node_t;
pub const NODE_ELSE = c.PM_ELSE_NODE;
pub const ArrayNode = c.pm_array_node_t;
pub const MultiWriteNode = c.pm_multi_write_node_t;
pub const NODE_MULTI_WRITE = c.PM_MULTI_WRITE_NODE;
pub const LocalVarTargetNode = c.pm_local_variable_target_node_t;
pub const NODE_LOCAL_VAR_TARGET = c.PM_LOCAL_VARIABLE_TARGET_NODE;
pub const CaseNode = c.pm_case_node_t;
pub const NODE_CASE = c.PM_CASE_NODE;
pub const WhenNode = c.pm_when_node_t;
pub const NODE_WHEN = c.PM_WHEN_NODE;
pub const ReturnNode = c.pm_return_node_t;
pub const NODE_RETURN = c.PM_RETURN_NODE;
pub const ForNode = c.pm_for_node_t;
pub const NODE_FOR = c.PM_FOR_NODE;
pub const BeginNode = c.pm_begin_node_t;
pub const NODE_BEGIN = c.PM_BEGIN_NODE;
pub const RescueNode = c.pm_rescue_node_t;
pub const NODE_RESCUE = c.PM_RESCUE_NODE;
pub const RescueModifierNode = c.pm_rescue_modifier_node_t;
pub const NODE_RESCUE_MODIFIER = c.PM_RESCUE_MODIFIER_NODE;
pub const LocalVarOrWriteNode = c.pm_local_variable_or_write_node_t;
pub const NODE_LOCAL_VAR_OR_WRITE = c.PM_LOCAL_VARIABLE_OR_WRITE_NODE;
pub const LocalVarAndWriteNode = c.pm_local_variable_and_write_node_t;
pub const NODE_LOCAL_VAR_AND_WRITE = c.PM_LOCAL_VARIABLE_AND_WRITE_NODE;
pub const LocalVarOpWriteNode = c.pm_local_variable_operator_write_node_t;
pub const NODE_LOCAL_VAR_OP_WRITE = c.PM_LOCAL_VARIABLE_OPERATOR_WRITE_NODE;

pub const CaseMatchNode = c.pm_case_match_node_t;
pub const NODE_CASE_MATCH = c.PM_CASE_MATCH_NODE;
pub const CapturePatternNode = c.pm_capture_pattern_node_t;
pub const NODE_CAPTURE_PATTERN = c.PM_CAPTURE_PATTERN_NODE;
pub const ArrayPatternNode = c.pm_array_pattern_node_t;
pub const NODE_ARRAY_PATTERN = c.PM_ARRAY_PATTERN_NODE;
pub const FindPatternNode = c.pm_find_pattern_node_t;
pub const NODE_FIND_PATTERN = c.PM_FIND_PATTERN_NODE;
pub const PinnedVariableNode = c.pm_pinned_variable_node_t;
pub const NODE_PINNED_VARIABLE = c.PM_PINNED_VARIABLE_NODE;
pub const HashPatternNode = c.pm_hash_pattern_node_t;
pub const NODE_HASH_PATTERN = c.PM_HASH_PATTERN_NODE;

// Loop & conditional nodes (Phase 29)
pub const WhileNode = c.pm_while_node_t;
pub const NODE_WHILE = c.PM_WHILE_NODE;
pub const UntilNode = c.pm_until_node_t;
pub const NODE_UNTIL = c.PM_UNTIL_NODE;
pub const UnlessNode = c.pm_unless_node_t;
pub const NODE_UNLESS = c.PM_UNLESS_NODE;
pub const EnsureNode = c.pm_ensure_node_t;
pub const NODE_ENSURE = c.PM_ENSURE_NODE;

// Control transfer (Phase 29)
pub const YieldNode = c.pm_yield_node_t;
pub const NODE_YIELD = c.PM_YIELD_NODE;
pub const SuperNode = c.pm_super_node_t;
pub const NODE_SUPER = c.PM_SUPER_NODE;
pub const ForwardingSuperNode = c.pm_forwarding_super_node_t;
pub const NODE_FORWARDING_SUPER = c.PM_FORWARDING_SUPER_NODE;

// Global variables (Phase 29)
pub const GlobalVarWriteNode = c.pm_global_variable_write_node_t;
pub const NODE_GLOBAL_VAR_WRITE = c.PM_GLOBAL_VARIABLE_WRITE_NODE;
pub const GlobalVarReadNode = c.pm_global_variable_read_node_t;
pub const NODE_GLOBAL_VAR_READ = c.PM_GLOBAL_VARIABLE_READ_NODE;

// Op-assign on method calls: user.name &&= x, cache ||= fetch (Phase 29)
pub const CallAndWriteNode = c.pm_call_and_write_node_t;
pub const NODE_CALL_AND_WRITE = c.PM_CALL_AND_WRITE_NODE;
pub const CallOrWriteNode = c.pm_call_or_write_node_t;
pub const NODE_CALL_OR_WRITE = c.PM_CALL_OR_WRITE_NODE;

// Ivar / classvar / globalvar / constant or-and-write (Phase 24)
pub const InstanceVarOrWriteNode = c.pm_instance_variable_or_write_node_t;
pub const NODE_INSTANCE_VAR_OR_WRITE = c.PM_INSTANCE_VARIABLE_OR_WRITE_NODE;
pub const InstanceVarAndWriteNode = c.pm_instance_variable_and_write_node_t;
pub const NODE_INSTANCE_VAR_AND_WRITE = c.PM_INSTANCE_VARIABLE_AND_WRITE_NODE;
pub const ClassVarOrWriteNode = c.pm_class_variable_or_write_node_t;
pub const NODE_CLASS_VAR_OR_WRITE = c.PM_CLASS_VARIABLE_OR_WRITE_NODE;
pub const ClassVarAndWriteNode = c.pm_class_variable_and_write_node_t;
pub const NODE_CLASS_VAR_AND_WRITE = c.PM_CLASS_VARIABLE_AND_WRITE_NODE;
pub const ConstantOrWriteNode = c.pm_constant_or_write_node_t;
pub const NODE_CONSTANT_OR_WRITE = c.PM_CONSTANT_OR_WRITE_NODE;
pub const ConstantAndWriteNode = c.pm_constant_and_write_node_t;
pub const NODE_CONSTANT_AND_WRITE = c.PM_CONSTANT_AND_WRITE_NODE;
pub const GlobalVarOrWriteNode = c.pm_global_variable_or_write_node_t;
pub const NODE_GLOBAL_VAR_OR_WRITE = c.PM_GLOBAL_VARIABLE_OR_WRITE_NODE;
pub const GlobalVarAndWriteNode = c.pm_global_variable_and_write_node_t;
pub const NODE_GLOBAL_VAR_AND_WRITE = c.PM_GLOBAL_VARIABLE_AND_WRITE_NODE;

// Numbered parameters: { _1 } blocks (Phase 29)
pub const NODE_NUMBERED_PARAMETERS = c.PM_NUMBERED_PARAMETERS_NODE;

pub fn nodeType(node: *const Node) NodeType {
    return node.*.type;
}
