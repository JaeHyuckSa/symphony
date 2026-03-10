defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Claude Code adapter that implements the agent backend interface.

  Spawns `claude -p` as a
  subprocess for each turn. Sessions are lightweight since Claude Code is stateless per invocation.
  """

  require Logger
  alias SymphonyElixir.Config

  @max_stream_log_bytes 1_000

  @type session :: %{
          workspace: Path.t(),
          model: String.t() | nil,
          allowed_tools: String.t() | nil,
          extra_flags: String.t() | nil,
          turn_timeout_ms: pos_integer(),
          metadata: map()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace) do
    with :ok <- validate_workspace_cwd(workspace) do
      expanded_workspace = Path.expand(workspace)

      {:ok,
       %{
         workspace: expanded_workspace,
         model: Config.claude_model(),
         allowed_tools: Config.claude_allowed_tools(),
         extra_flags: Config.claude_extra_flags(),
         turn_timeout_ms: Config.claude_turn_timeout_ms(),
         metadata: %{}
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          workspace: workspace,
          model: model,
          allowed_tools: allowed_tools,
          extra_flags: extra_flags,
          turn_timeout_ms: turn_timeout_ms
        } = _session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    session_id = generate_session_id()
    turn_id = generate_turn_id()

    Logger.info("Claude Code session started for #{issue_context(issue)} session_id=#{session_id}")

    emit_message(on_message, :session_started, %{
      session_id: session_id,
      thread_id: session_id,
      turn_id: turn_id
    })

    cmd = build_command(prompt, model, allowed_tools, extra_flags, workspace)

    case run_claude_process(cmd, prompt, workspace, turn_timeout_ms, on_message) do
      {:ok, output} ->
        usage = extract_usage(output)
        emit_message(on_message, :turn_completed, %{
          session_id: session_id,
          output: output,
          payload: %{"method" => "turn/completed", "usage" => usage},
          usage: usage,
          raw: output
        })

        Logger.info("Claude Code session completed for #{issue_context(issue)} session_id=#{session_id}")

        {:ok,
         %{
           result: :turn_completed,
           session_id: session_id,
           thread_id: session_id,
           turn_id: turn_id
         }}

      {:error, reason} ->
        emit_message(on_message, :turn_ended_with_error, %{
          session_id: session_id,
          reason: reason
        })

        Logger.warning(
          "Claude Code session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  # -- Private --

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())
    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace_cwd, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  defp build_command(prompt, model, allowed_tools, extra_flags, workspace) do
    # Write prompt to a temp file to avoid arg length limits
    prompt_file = Path.join(workspace, ".symphony_prompt.tmp")
    File.write!(prompt_file, prompt)

    cmd = [
      "sh", "-c",
      "cat #{escape_shell(prompt_file)} | claude -p - --output-format json" <>
        if_flag("--model", model) <>
        if_flag("--allowedTools", allowed_tools_with_mcp(allowed_tools)) <>
        if_extra(extra_flags) <>
        "; rm -f #{escape_shell(prompt_file)}"
    ]

    cmd
  end

  defp allowed_tools_with_mcp(allowed_tools) do
    if is_binary(allowed_tools) and allowed_tools != "" do
      allowed_tools <> ",mcp__linear-api__*"
    else
      "mcp__linear-api__*"
    end
  end

  defp if_flag(_flag, val) when is_nil(val) or val == "", do: ""
  defp if_flag(flag, val), do: " #{flag} #{escape_shell(val)}"

  defp if_extra(val) when is_nil(val) or val == "", do: ""
  defp if_extra(val), do: " " <> val

  defp escape_shell(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  defp run_claude_process(cmd, _prompt, workspace, timeout_ms, on_message) do
    [executable | args] = cmd
    exe_path = System.find_executable(executable)

    if is_nil(exe_path) do
      {:error, {:claude_not_found, executable}}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(exe_path)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(args, &String.to_charlist/1),
            cd: String.to_charlist(workspace),
            env: clean_env()
          ]
        )

      # Report OS PID to dashboard
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          emit_message(on_message, :notification, %{
            agent_pid: to_string(os_pid),
            payload: %{"method" => "pid_report"},
            raw: "claude pid=#{os_pid}"
          })
        _ -> :ok
      end

      collect_output(port, timeout_ms, on_message, "")
    end
  end

  defp clean_env do
    # CLAUDECODE 환경변수를 해제하여 중첩 세션 차단 우회
    System.get_env()
    |> Map.delete("CLAUDECODE")
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp collect_output(port, timeout_ms, on_message, acc) do
    receive do
      {^port, {:data, data}} ->
        chunk = to_string(data)

        # 스트리밍 중 활동 알림
        emit_message(on_message, :notification, %{
          payload: %{"method" => "streaming", "data" => String.slice(chunk, 0, 200)},
          raw: String.slice(chunk, 0, @max_stream_log_bytes)
        })

        collect_output(port, timeout_ms, on_message, acc <> chunk)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, status}} ->
        Logger.error("Claude Code exited with status #{status}: #{String.slice(acc, 0, 500)}")
        {:error, {:claude_exit, status, String.slice(acc, 0, 500)}}
    after
      timeout_ms ->
        Port.close(port)
        {:error, :turn_timeout}
    end
  end

  defp extract_usage(output) do
    output = String.trim(output)

    # 마지막 줄의 JSON 파싱 시도
    output
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(%{}, fn line ->
      line = String.trim(line)

      if String.starts_with?(line, "{") do
        case Jason.decode(line) do
          {:ok, parsed} -> extract_usage_from_parsed(parsed)
          _ -> nil
        end
      else
        nil
      end
    end)
  end

  defp extract_usage_from_parsed(parsed) when is_map(parsed) do
    usage = Map.get(parsed, "usage", parsed)
    result = %{}

    result =
      case find_key(usage, ["input_tokens", "prompt_tokens", "inputTokens", "promptTokens"]) do
        nil -> result
        val -> Map.put(result, "input_tokens", val)
      end

    result =
      case find_key(usage, ["output_tokens", "completion_tokens", "outputTokens", "completionTokens"]) do
        nil -> result
        val -> Map.put(result, "output_tokens", val)
      end

    result =
      case find_key(usage, ["total_tokens", "totalTokens"]) do
        nil ->
          input = Map.get(result, "input_tokens", 0)
          output = Map.get(result, "output_tokens", 0)

          if input > 0 or output > 0 do
            Map.put(result, "total_tokens", input + output)
          else
            result
          end

        val ->
          Map.put(result, "total_tokens", val)
      end

    cost = find_key(parsed, ["cost_usd"]) || find_key(usage, ["cost_usd"])
    result = if cost, do: Map.put(result, "cost_usd", cost), else: result

    result
  end

  defp find_key(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp find_key(_, _), do: nil

  defp emit_message(on_message, event, details) when is_function(on_message, 1) do
    message =
      details
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp generate_session_id do
    "claude-#{:crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)}"
  end

  defp generate_turn_id do
    "turn-#{:crypto.strong_rand_bytes(4) |> Base.hex_encode32(case: :lower, padding: false)}"
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
