[
  # Mix.Task callback info not available in dialyzer PLT
  {"lib/mix/tasks/spark.ex", :callback_info_missing},
  {"lib/mix/tasks/spark.ex", :unknown_function},

  # Mix.env/0 is compile-time, not available to dialyzer
  {"lib/spark/application.ex", :unknown_function},

  # CLI module is deprecated — IO.gets return type issues
  {"lib/spark/cli.ex", :guard_fail},
  {"lib/spark/cli.ex", :pattern_match},
  {"lib/spark/cli.ex", :pattern_match_cov},
  {"lib/spark/cli.ex", :no_return},
  {"lib/spark/cli.ex", :call},

  # Guidance: valid_rule? catch-all is intentional defensive pattern
  {"lib/spark/guidance.ex", :pattern_match},
  {"lib/spark/guidance.ex", :pattern_match_cov},

  # Watcher: nil guard from File.cwd! fallback
  {"lib/spark/hot_reload/watcher.ex", :guard_fail},

  # Bronze: truncate_payload catch-all is intentional
  {"lib/spark/memory/bronze.ex", :pattern_match_cov},

  # PromptRefiner: extract_content guard on map is intentional
  {"lib/spark/prompt_refiner.ex", :guard_fail},

  # ToolRunner: format_error catch-all is intentional defensive pattern
  {"lib/spark/tool_runner.ex", :pattern_match_cov},

  # TermUI external dep opaque type issues — not our code
  {"lib/spark/term_ui_debug.ex", :call_without_opaque},
  {"lib/spark/tui/layout.ex", :call_without_opaque},
  # TermUI internal macro generates unreachable comparison + unknown warning type
  {"lib/spark/tui/update.ex", :unknown_warning},
  {"lib/spark/tui/update.ex:226", :unknown_warning}
]
