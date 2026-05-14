Hammox.defmock(Pageless.Svc.GeminiClient.Mock,
  for: Pageless.Svc.GeminiClient.Behaviour
)

Hammox.defmock(Pageless.Svc.MCPClient.Mock,
  for: Pageless.Svc.MCPClient.Behaviour
)

Hammox.defmock(Pageless.Svc.ResolveClient.Mock,
  for: Pageless.Svc.ResolveClient.Behaviour
)

Hammox.defmock(Pageless.Tools.Kubectl.Mock,
  for: Pageless.Tools.Kubectl.Behaviour
)

Hammox.defmock(Pageless.Tools.MCPRunbook.Mock,
  for: Pageless.Tools.MCPRunbook.Behaviour
)

case Code.ensure_compiled(Pageless.Tools.PrometheusQuery.Behaviour) do
  {:module, Pageless.Tools.PrometheusQuery.Behaviour} ->
    Hammox.defmock(Pageless.Tools.PrometheusQuery.Mock,
      for: Pageless.Tools.PrometheusQuery.Behaviour
    )

  {:error, _reason} ->
    :ok
end

Hammox.defmock(Pageless.Tools.QueryDB.Mock,
  for: Pageless.Tools.QueryDB.Behaviour
)

Hammox.defmock(Pageless.AuditTrailMock, for: Pageless.AuditTrail.Behaviour)
