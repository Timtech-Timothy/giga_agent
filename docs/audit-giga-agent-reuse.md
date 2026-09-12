# Аудит GigaAgent: что переиспользовать для детерминированного LangGraph

**Статус:** только исследование, без реализации.  
**Объект:** этот репозиторий (форк `ai-forever/giga_agent`). Папка `front/` не анализировалась.  
**Цель аудита:** понять, какие куски платформы (чекпойнтер, sandbox, LLM-слой, MCP, auth) можно взять как инфраструктуру для НИОКР-платформы с **заранее заданным графом состояний**, а не с ReAct-циклом «модель сама выбирает следующий инструмент».

Краткий ответ: **инфраструктура (рантаймы, sandbox, модули, ACL, Alembic приложения) переиспользуема; агентное ядро ReAct — нет.** Postgres-чекпойнтера LangGraph в этом репозитории нет: в dev — SQLite, в Docker — отдельная БД Aegra.

---

## Сводная таблица

| Компонент | Вердикт | Почему |
|-----------|---------|--------|
| LangGraph ↔ Postgres checkpointer | **нужна адаптация** | В коде нет `langgraph-checkpoint-postgres` / `AsyncPostgresSaver`. Dev: `AsyncSqliteSaver` + кастомная фабрика. Prod: чекпойнты живут в **отдельной** Postgres Aegra (`langgraph-postgres`), миграции — внутри образа `mikelarg/aegra`, не в Alembic приложения. Паттерн «граф компилируется без чекпойнтера, сервер инжектит» — переносим. Сами таблицы чекпойнтов **напрямую не переиспользуются**. |
| Alembic приложения (`core_*`) | **пригоден как есть** (как каркас) | Двухуровневые миграции: `alembic_version` (core) + `alembic_version_<module.id>`. Ни одна миграция не создаёт `checkpoints` / `checkpoint_writes`. Можно копировать раннер и политику, не схему чекпойнтов. |
| Sandbox API (`BaseSandbox` / `CodeMixin.run_code`) | **пригоден как есть** | Три бэкенда за одним интерфейсом: `local_docker`, `e2b`, `local_jupyter`. Стрим stdout/stderr/traceback, файлы, shell. Вызывать из **узла графа**, не через ReAct-tool `python`. |
| Sandbox-образ / лимиты под CadQuery | **нужна адаптация** | Образ — data/ML/viz (numpy/scipy/pandas/plotly), **без CadQuery/OCP**. Дефолт Docker: 2 GB RAM, 1 vCPU. Нет GPU. Нет per-cell timeout (плюс), есть idle 3600s и preempt ядра при новом `run_code`. STL/STEP класть в `/bucket`. |
| LLM-абстракция (connector + runtime + registry) | **нужна адаптация** | Чистый паттерн: `ConnectorRegistry` + `LLMRegistry` + `RuntimeResolver`. Провайдеры: **openai, gigachat, deepseek**. Anthropic **нет**. Каскадного фолбэка провайдеров **нет** (только `fast_llm → llm`). Anthropic = новый connector+runtime по тому же шаблону. |
| Каталог MCP / `ToolSource` | **нужна адаптация** | Формат MCP (HTTP/stdio, `catalog.json`, `mcp.json`, DB `core_mcp_servers`) и клиент (`list_server_tools` / `call_server_tool`) можно взять. Мета-тулы `connector_get_info` / `connector_call_tool` — **ReAct-доставка**: модель сама выбирает инструмент. Для фиксированного графа вызывать MCP/CadQuery **из узла**, не через `bind_tools`. CadQuery лучше как sandbox-код или нативный модуль, не как MCP, если не нужна процессная изоляция. |
| Auth (JWT + cookie + роли) | **нужна адаптация** | JWT (PyJWT) + cookie `access_token` + bcrypt. Роли `owner/admin/member`, группы, ACL на ресурсы. **Инстанс = одна команда** (`core/team.py`). Нет `tenant_id` / организации. Изоляция application-level (`owner_id` + `EXISTS` в ACL), не Postgres RLS. Для нескольких команд/треков соревнования — добавить тенант или деплоить по инстансу на команду. |
| HITL (`interrupt`) | **нужна адаптация** | Примитив LangGraph `interrupt()` переиспользуем. Текущие паузы завязаны на **после tool_calls модели** (`ToolResultMiddleware`: `approve` / `tool_call`). Для «стоп перед прошивкой / силовой электроникой» нужны **узловые** interrupt в своём графе, не этот middleware. |
| ReAct-ядро (`create_graph`, `ToolNode`, think, REPL-как-главный-tool) | **не подходит** | Классический цикл `model → (pending tool_calls?) → tools → model`. Копирование «по аналогии» втащит свободный выбор инструмента моделью и сломает детерминированный граф. |
| Deep Research graph | **пригоден как образец** | Уже фиксированный `StateGraph`: `planner → search → read → reflect ⇄ compose → critique → finalize`. Обёртка `@tool run_deep_research` — ReAct-слой, его отбросить. Паттерн «узел вызывает конкретную LLM под задачу» — то, что нужно. |
| `RuntimeResolver` / CLI conf | **пригоден как есть** | DB-режим (`user.llm_id` и т.д.) и CLI (`giga_agent.conf.json`, `__type`). Узлы графа должны резолвить LLM через `resolver.get_llm()`, не через `user.llm_id` напрямую. |
| Aegra / dual Postgres / LangGraph HTTP API | **нужна адаптация** (скорее опциональная платформа) | Prod-стек завязан на `mikelarg/aegra`: threads/runs API, Redis, отдельная БД чекпойнтов. Для своего FastAPI+LangGraph это тяжёлая зависимость. Можно жить без Aegra, подключив `AsyncPostgresSaver` сами. |
| Фронтенд чата | **не подходит** (вне скоупа) | Заточен под общий чат. Не разбирался. |

---

## 1. LangGraph и Postgres-чекпойнтер

### Как устроено на самом деле

Чекпойнтер **не пришит** к графу агента. `create_graph(..., checkpointer=None)` компилирует граф без сейвера; инжект делает рантайм:

| Режим | Что реально хранит состояние | Где |
|-------|------------------------------|-----|
| `giga_agent dev` / langgraph-api | `AsyncSqliteSaver` | `.giga_agent/checkpoints.sqlite` (или `GIGA_AGENT_CHECKPOINTER_SQLITE_PATH`) |
| CLI chat | тот же `AsyncSqliteSaver` | `.giga_agent/langgraph/checkpoints.db` |
| Docker / prod | Aegra на Postgres | сервис `langgraph-postgres`, БД `aegra` |
| Приложение (пользователи, LLM, файлы) | свой Postgres/SQLite | `GIGA_AGENT_DATABASE_URL` → `giga-agent-postgres` |

Зависимость в `pyproject.toml`: только `langgraph-checkpoint-sqlite`. **`langgraph-checkpoint-postgres` нет.** `langchain-postgres` / `psycopg` — для RAG/векторов, не для чекпойнтов.

Фабрика SQLite:

- `backend/giga_agent/core/sqlite_checkpointer.py` — `CHECKPOINTER_CONFIG = {backend: custom, path: ...create_checkpointer}`
- таблицы SQLite (`checkpoints`, `writes`) создаёт `AsyncSqliteSaver` лениво, **не Alembic**

Prod Docker (`docker-compose.yml`):

```
POSTGRES_URI / DATABASE_URL  →  langgraph-postgres / aegra     (Aegra + LangGraph)
GIGA_AGENT_DATABASE_URL      →  giga-agent-postgres / postgres (приложение)
```

Миграции Aegra: `deployments/aegra-startup.sh` → `alembic -c /aegra-api/alembic.ini upgrade head` **внутри образа**, не в этом репо. Стандартные таблицы `langgraph-checkpoint-postgres` (ожидаемые, не вендоренные здесь): `checkpoint_migrations`, `checkpoints`, `checkpoint_blobs`, `checkpoint_writes`.

### Alembic приложения

- Конфиг: `backend/giga_agent/alembic.ini`, env: `backend/giga_agent/migrations/env.py`
- Скрипты core: `backend/giga_agent/models/migrations/`
- Раннер: `backend/giga_agent/core/migrations.py` — сначала core (`alembic_version`), потом модули (`alembic_version_<id>`)
- Автоприменение на старте агента

**Ни одна core-миграция не создаёт checkpoint-таблицы.** Единственная связь с LangGraph в app-схеме — `core_channel_threads.langgraph_thread_id` (миграция `2026_04_02_1801-cb8c1f67cd6c_.py`): зеркало id треда для Telegram/каналов, не блобы состояния.

Идентичность сессии: ключ — `configurable.thread_id`. `checkpoint_id` используется в history/fork API (`routes/threads.py`). `checkpoint_ns` почти не трогают (пустая строка при resume experimental).

### Можно ли переиспользовать напрямую?

- **Паттерн** «compile без checkpointer + инжект на сервере» — да.
- **SQLite-фабрику** — да, для локалки.
- **Postgres-схему чекпойнтов из этого репо** — нечего копировать. Нужно самим подключить `langgraph-checkpoint-postgres.AsyncPostgresSaver` (или оставить Aegra).
- **Alembic приложения** — да как каркас миграций домена (проекты, юзеры, ACL), нет как миграции графа.

Для НИОКР-платформы разумнее **одна** Postgres: доменные таблицы + стандартный PostgresSaver, без dual-DB Aegra, пока не понадобится LangGraph Platform API (threads/runs/streaming as-a-service).

---

## 2. Sandbox: Docker SDK / E2B / Jupyter

### Интерфейс

Единый контракт:

- `BaseSandbox` — `backend/giga_agent/sandbox/base.py` (`up` / `stop` / `is_up`, файлы)
- `CodeMixin.run_code` — `sandbox/mixins/code.py`: стрим чанков; `run_shell` / `await_shell`
- Реестр: `sandbox/registry.py` — `@SandboxRegistry.register`
- Менеджер: `sandbox/manager/facade.py` (`ensure_running_for_user`)
- Резолв: `RuntimeResolver.get_sandbox()` / `has_sandbox`

Провайдеры:

| Ключ | Класс | Изоляция |
|------|--------|----------|
| `local_docker` | `LocalDockerSandbox` | контейнер `giga-sandbox-{id}`, bind-mount `{files}/{owner_id}` → `/bucket` |
| `e2b` | `E2BSandbox` | облачная VM E2B + s3fs → `/bucket/` |
| `local_jupyter` | `LocalJupyterSandbox` | Jupyter на хосте; опционально `bwrap`/`sandbox-exec` |

`local_docker` и `e2b` ходят в in-guest SandboxAPI (`backend/sandbox/server/`, порт 49999) по WebSocket `/v1/kernels/{id\|new}/execute`. Это не голый `exec()`: **stateful IPython kernel `python3`**.

### Таймауты и вывод

| Что | Поведение |
|-----|-----------|
| Таймаут ячейки `run_code` | **нет** — крутится до idle/preempt/смерти процесса |
| Idle провайдера | 3600 с (`SandboxProvider.idle_timeout`) |
| E2B lifetime | поле `timeout` при `AsyncSandbox.create` (перекрывается idle провайдера) |
| Старт Docker/API | 20 с / 30 с |
| Shell foreground | `block_until_ms=30000`, дальше background + `await_shell` |
| Concurrent cell | preempt: soft SIGINT 5 с, затем рестарт ядра |

Чанки стрима: `stdout`/`stderr` (`text`), `result`/`display_data` (MIME), `error` (`ename`, `evalue`, `traceback[]`), `input_request`, `done`. REPL (`modules/repl/tools.py`) агрегирует это в tool-сообщение и снимает ANSI с traceback.

### Изоляция сессий

- Docker: один контейнер на sandbox, labels `giga_agent.*`, FS по `owner_id`. Сеть **не** `none` по умолчанию (published port или docker-сеть). Лимиты: 2048 MB, 1.0 vCPU, pids 256, shm 128 MB, max 3 активных.
- E2B: отдельная VM + S3-префикс владельца.
- local_jupyter: общее ядро на хосте, LRU ядер на пользователя (до 5). Для мультиарендности **слабо**.

GPU нигде не прокидывается.

### CadQuery / расчётный код

Архитектуру вызова **брать как есть**: узел графа → `SandboxManager.ensure_running_for_user` → `run_code(cadquery_script)` → стрим ошибок → артефакты в `/bucket`.

Доработать обязательно:

1. Образ: `backend/sandbox/requirements.txt` + `Dockerfile` — добавить CadQuery/OCP (и apt-зависимости OCCT), пересобрать `mikelarg/code-interpreter` / E2B template (`sandbox/template_builder.py`).
2. Ресурсы: 2 GB / 1 CPU мало для BREP. Поднять `GIGA_AGENT_LOCAL_DOCKER_MEMORY_LIMIT_MB` / `VCPU`; для E2B — больший template.
3. Idle: длинные расчёты > часа — поднять `idle_timeout`; не запускать второй `run_code` на том же ядре (preempt).
4. Артефакты: писать STL/STEP/STEP-XML только под `/bucket/...` (host bind или S3). `/tmp` умрёт со sandbox.
5. Не тащить `modules/repl` как «главный инструмент агента»: это ReAct-обёртка. Нужен прямой вызов `run_code` из узла «сгенерировать/провалидировать геометрию».
6. HITL перед опасным кодом (прошивка, силовая) — не sandbox, а `interrupt()` в графе **до** вызова.

`local_jupyter` годится только для соло-CLI; для команд — `local_docker` после кастомного образа.

---

## 3. Слой LLM-провайдеров

Два уровня:

1. **Connector** — секреты/endpoint (`BaseConnector`, таблица `core_connectors`).
2. **LLM runtime** — LangChain chat model из connector + `model_id` + settings (`BaseLLMRuntime`, таблица `core_llms`).

Реестры: `connectors/registry.py`, `llm/registry.py`. Сборка: `LLMManager.resolve_by_id` → runtime.`get_llm()`.

Зарегистрировано:

| `__type` | Connector | Runtime | LangChain |
|----------|-----------|---------|-----------|
| `openai` | `OpenAIConnector` | `OpenAIRuntime` | `ChatOpenAI` |
| `gigachat` | `GigaChatConnector` | `GigaChatRuntime` | `langchain_gigachat.GigaChat` |
| `deepseek` | `DeepSeekConnector` | `DeepSeekRuntime` | `ChatDeepSeek` |

**Anthropic отсутствует** (поиск по `backend/giga_agent` пустой). OpenAI-совместимый шлюз можно закрыть через `OpenAIConnector.base_url`. В зависимостях есть `google-genai` — не как chat-LLM runtime в этом слое.

Конфиг:

- DB: `User.llm_id` / `User.fast_llm_id`; `LLMSettings`: temperature, max_tokens, top_p, extra JSON.
- CLI: `giga_agent.conf.json`, дискриминатор `__type` (`core/agent/cli_conf.py`).
- Метаданные окон/цен: `models_config.json` (не рантайм).

Фолбэки:

- `fast_llm` падает на primary, если fast не задан.
- **Нет** `with_fallbacks` / каскада GPT→GigaChat→Anthropic при ошибке провайдера.
- Analyze-images: primary, затем fast, если primary не умеет картинки.
- Субагенты: опциональный секрет `SUBAGENTS_LLM`, иначе primary.

Стриминг: у GigaChat явно `streaming=True`. Tool-calling в **ReAct**-фабрике: `llm.bind_tools(...)`. Structured output через `with_structured_output` **не используется**; в deep_research — `bind_tools(submit_*)` внутри узла (это нормально и для фиксированного графа).

Для НИОКР: копировать connector/runtime/resolver; каждый узел графа вызывает **назначенную** модель (`resolver.get_llm()` / отдельный `get_fast_llm()`). Anthropic — новый класс по образцу `llm/openai.py`. Если нужен железный фолбэк провайдера — писать самим (сейчас его нет).

---

## 4. Каталог MCP и формат инструментов

Документация: корневые `TOOLS.md` и `SUBAGENTS.md`. `TOOLS.md` слегка отстаёт от кода: описывает `BaseModule.get_tools()` + `@tool`, но в коде ещё есть `lazy_tools=True` и протокол `ToolSource`. Пути субагентов в `SUBAGENTS.md` частично устарели (`backend/graph/...` → фактически `modules/subagents_legacy/`).

### Три способа зарегистрировать способность

| Способ | Как | Когда |
|--------|-----|--------|
| Нативный модуль | `@tool` + `BaseModule._get_tools` / `get_tools` | In-process: состояние проекта, обёртка над своей БД |
| MCP | HTTP или stdio; запись в `core_mcp_servers` / `.giga_agent/mcp.json` / UI-каталог | Чужой продукт, процессная изоляция |
| Субграф | `get_subgraphs()` + `@tool`, который запускает граф | Многошаговый пайплайн (как deep_research) |

Каталог MCP (`modules/mcp/catalog.json`): шаблоны quick-connect (`id`, `url`, `auth_type`: none/bearer/oauth2, `requires`, categories). Это **не** живые коннекты — сиды для `POST /servers`.

Живой клиент: `modules/mcp/client.py` — streamable HTTP + stdio, таймауты connect 15 с / tool 60 с / SSE 300 с, кэш discovery 10 мин, семафор 4 сессии на сервер, кап ответа 25 MB.

Единый ленивый протокол:

```python
class ToolSource(Protocol):  # core/agent/connectors/sources.py
    async def list_tools(...) -> list[ToolSpec]
    async def call_tool(...) -> ToolCallOutcome
```

Реализации: `ModuleToolSource` (нативные lazy-модули), `McpToolSource`. Агент видит их через мета-тулы `connector_get_info` / `connector_call_tool` — **модель сама решает, что вызвать**. Это ReAct.

### CadQuery и состояние проекта — в том же формате?

- **Протокол MCP / `ToolSource` копировать не обязательно**, если узлы графа зовут код напрямую.
- Если нужен единый каталог внешних интеграций (GitHub, ERP, плюс «проект робота») — формат `catalog.json` + `ResolvedServer` + `call_server_tool` **подходит**, и свой wire-protocol изобретать не нужно.
- CadQuery: предпочтительно **не MCP**. Это тяжёлый Python/OCCT в sandbox. Варианты:
  1. Узел графа → `sandbox.run_code(...)` (лучший fit).
  2. Нативный `BaseModule` с функциями `build_part` / `export_step`, которые внутри зовут sandbox — но вызывать их из узла, **не** отдавать модели в `bind_tools`.
  3. MCP-сервер вокруг CadQuery — только если хотите отдельный процесс и стандартный MCP для сторонних клиентов.

REPL-tools (`modules/repl/repl_tools/`) — функции **внутри** песочницы с доступом к секретам бэкенда. Для расчётов это ближе, чем LLM-tools, но текущая обвязка заточена под агента, который пишет Python сам.

---

## 5. Аутентификация и изоляция данных

### Механизмы

- JWT (PyJWT), Bearer + cookie `access_token` при логине.
- Пароли bcrypt. `ACCESS_TOKEN_EXPIRE_MINUTES = None` — **токены по умолчанию бессрочные**.
- LangGraph Auth: `modules/auth/langgraph_auth.py` валидирует JWT, пишет `metadata.user_id` на threads/runs, фильтр `{"user_id": identity}`.
- OAuth — только интеграции (MCP, Yandex и т.п.), не SSO логина пользователя.
- Пользовательских API keys нет. Sandbox: opaque Redis capability tokens.

Модель команды явно в коде:

```text
# models/users.py + core/team.py
Инстанс = одна команда
роли: owner > admin > member
системная группа «All Members» — ресурс, расшаренный на неё, виден всей команде
```

Нет таблиц Organization / Tenant / Track.

### Скоп данных

| Данные | Как режется |
|--------|-------------|
| Threads / runs (LangGraph) | metadata `user_id`, не SQL ACL |
| Файлы, RAG, sandbox, LLM, connector, MCP | `owner_id` + `core_resource_permissions` (user/group/`*`, read/write) |
| Projects | только `owner_id`, без group-share |
| Qdrant | общий collection, фильтр payload `owner_id` |
| Sandbox FS | префикс `{root}/{owner_id}/` |

**Postgres RLS нет.** Любой пропущенный фильтр = IDOR. Qdrant-изоляция держится на том, что каждый запрос клеит `owner_id`.

### Мультиарендность (команды / треки соревнования)

Как есть: **один деплой = одна команда**. Несколько конкурирующих команд в одной БД — нечестно и небезопасно (админы инстанса, All Members, нет tenant-ключа на тредах).

Рабочие пути:

1. **Один инстанс (или отдельная БД) на команду/трек** — без правок модели, операционно тяжело.
2. **Добавить `team_id`/`tenant_id`** везде (users, threads metadata, files, Qdrant, sandbox root, ACL) — адаптация auth/ACL, не с нуля.

Базу JWT + User + Group + ResourcePermission **брать**; концепцию «инстанс = команда» — ломать или изолировать деплоем.

---

## 6. Что жёстко завязано на ReAct (зона риска)

Главный агент — классический ReAct. Маршрутизация буквально «есть ли pending `tool_calls`?»:

```301:348:backend/giga_agent/core/agent/graph_factory.py
def _make_model_to_tools_edge(...):
    # if len(last_ai_message.tool_calls) == 0: return end
    # if pending_tool_calls: Send("tools", ...)
```

Цикл: `before_agent → before_model → model → after_model ⇄ tools → after_agent`. Это продукт, а не конфиг.

### Не копировать (сломает фиксированный граф)

| Путь | Почему |
|------|--------|
| `core/agent/graph_factory.py` | Весь model↔tools цикл, `bind_tools`, recursion_limit 10_000 |
| `core/agent/tool_node.py` | Диспетчер `AIMessage.tool_calls` через `Send` |
| `core/agent/tools.py` | `think`, `multi_tool_use` — мета-тулы ReAct |
| `core/agent/think.py`, `multi_tool_use.py` | Принудительные think-хопы и раскрытие parallel calls |
| `core/agent/prompt.py`, `few_shots.py`, `few_shots_single.py` | Промпт автономного tool-агента |
| `core/agent/anti_loop.py`, `repair.py` | Детект циклов и починка dangling tool_calls |
| `middlewares/repair_messages.py`, `middlewares/tool_result.py` | HITL после tool_calls (`interrupt({type: approve\|tool_call})`) |
| `modules/frontend_mcp/` | Interrupt на client MCP tools |
| `modules/tool_router/` | Динамический subset `bind_tools` (GigaChat) |
| `modules/repl/module.py`, `tools.py`, `prompts.py` | REPL как **главный** инструмент; «работай через python» |
| `modules/clarify/tools.py` | HITL как tool, который агент сам вызывает |
| `agents/giga_agent.py`, `agents/experimental/graph.py` | Сборка ReAct + обёртка, которая поллит внутренний ReAct |
| `core/agent/connectors/tools.py` (`connector_get_info` / `connector_call_tool`) | Ленивая доставка каталога **модели** |
| `services/prompt_suggestions.py` | Ожидает pending approve/tool_call в стейте |
| `utils/messages.py` (`filter_tool_calls`) | Контракт чат-транскрипта |

Сообщение-контракт чекпойнтов/UI: `AIMessage.tool_calls` + `ToolMessage`. Свой граф должен иметь **свой** TypedDict стейта (как `DeepResearchState`), а не этот message-loop.

HITL в `tool_result.py` **не** сработает, если узлы не эмитят tool_calls. Для опасных шагов: `interrupt()` внутри конкретного узла («прошить MCU», «включить силовую») со своим payload (не `{type: approve}`).

### Можно брать независимо от ReAct

См. список файлов ниже. Образец фиксированного графа: `modules/deep_research/graph.py` (узлы зовут LLM/search напрямую; `@tool run_deep_research` — отбросить).

---

## Кандидаты на прямое переиспользование (файлы / модули)

Инфраструктура, не агентный цикл. Копировать/форкать как библиотеку платформы; вызывать из **своих** узлов.

### Чекпойнтер и миграции

- `backend/giga_agent/core/sqlite_checkpointer.py`
- `backend/giga_agent/core/migrations.py`
- `backend/giga_agent/migrations/env.py`
- `backend/giga_agent/alembic.ini`
- `backend/giga_agent/models/migrations/` (как образец core-схемы и политики, не как checkpoint DDL)
- `backend/giga_agent/core/db.py`

Не брать как «Postgres checkpointer»: его нет. Добавлять `langgraph-checkpoint-postgres` отдельно. Aegra (`deployments/aegra-startup.sh`, dual Postgres в `docker-compose.yml`) — только если сознательно оставляете LangGraph Platform.

### Sandbox

- `backend/giga_agent/sandbox/base.py`
- `backend/giga_agent/sandbox/mixins/code.py`
- `backend/giga_agent/sandbox/registry.py`
- `backend/giga_agent/sandbox/manager/`
- `backend/giga_agent/sandbox/local_docker/`
- `backend/giga_agent/sandbox/e2b/`
- `backend/giga_agent/sandbox/local_jupyter/`
- `backend/giga_agent/sandbox/jupyter.py`, `api_backed.py`, `sandbox_api/`
- `backend/giga_agent/sandbox/idle_sweeper.py`, `access.py`
- `backend/sandbox/server/` (in-guest API)
- `backend/sandbox/Dockerfile`, `requirements.txt`, `template_builder.py` — как база образа, с доработкой под CadQuery

Не брать: `modules/repl/` как UX агента.

### LLM / рантаймы

- `backend/giga_agent/core/agent/runtime_resolver.py`
- `backend/giga_agent/core/agent/cli_conf.py`
- `backend/giga_agent/connectors/` (`base`, `registry`, `openai`, `gigachat`, `deepseek`)
- `backend/giga_agent/llm/` (`base`, `registry`, `manager`, `openai`, `gigachat`, `deepseek`)
- `backend/giga_agent/models/connector.py`, `models/llm.py`, `models/users.py` (поля `*_id`)

### MCP / модули (без ReAct-доставки)

- `backend/giga_agent/core/module.py` (`BaseModule`: id, миграции, API router, secrets)
- `backend/giga_agent/modules/mcp/client.py`, `resolved.py`, `catalog.py`, `catalog.json`, `local_config.py`, `models/mcp_server.py`
- `backend/giga_agent/core/agent/connectors/sources.py` — `ToolSpec` / `ToolCallOutcome` как DTO, **не** мета-тулы

### Auth / ACL / команда

- `backend/giga_agent/modules/auth/security.py`, `api.py`, `langgraph_auth.py`, `invites_api.py`
- `backend/giga_agent/models/users.py`, `group.py`, `invite.py`
- `backend/giga_agent/models/resource_permission.py`, `models/_acl.py`
- `backend/giga_agent/core/team.py` — понять и **заменить** модель «один инстанс = одна команда»

### Образец детерминированного графа

- `backend/giga_agent/modules/deep_research/graph.py`
- `backend/giga_agent/modules/deep_research/nodes/*`
- `backend/giga_agent/modules/deep_research/config.py`
- `backend/langgraph.json` — как реестр именованных графов (свой граф рядом с `deep_research`, без `giga_agent` ReAct)

### Прочее платформенное

- `backend/giga_agent/models/file.py`, sandbox FS helpers — артефакты STEP/STL
- `backend/giga_agent/models/project.py` — зачаток «проекта», без шаринга на группу
- `backend/giga_agent/utils/langgraph_sdk.py` — `get_user_id_from_config` (Aegra отдаёт BaseModel, не dict)

---

## Рекомендуемый план (без кода, жду подтверждения)

1. **Не форкать агентное ядро.** Свой `StateGraph` по образцу deep_research: узлы ТЗ → механика (CadQuery в sandbox) → электроника → автономность, с `interrupt()` на опасных переходах.
2. **Чекпойнтер:** `AsyncPostgresSaver` в той же Postgres, что домен; SQLite-фабрику оставить для dev. Aegra не тащить, пока не нужен их HTTP threads API.
3. **Sandbox:** интерфейс как есть; новый образ с CadQuery; лимиты RAM/CPU; артефакты в `/bucket`.
4. **LLM:** connector/runtime/resolver как есть; добавить Anthropic тем же паттерном; фолбэк провайдеров — отдельное решение.
5. **Инструменты:** CadQuery и state проекта вызывать из узлов; MCP-клиент — для внешних систем, не как способ модели выбирать шаг.
6. **Мультиарендность:** либо инстанс на команду, либо проектировать `tenant_id` сразу; текущий ACL годится внутри команды.

Ничего из этого не имплементировано. Дальше — только после подтверждения таблицы и плана.
