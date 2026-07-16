"""ChatHub 适配器包。

broker 按 config.yaml 里的 `class` 字段（形如 "adapters.deepseek:DeepSeekAdapter"）
动态载入各席位适配器。未落地的适配器会被 broker 容错跳过，不影响其它席位。
"""
