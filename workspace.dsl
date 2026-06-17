workspace "Plataforma de Mobilidade" "Modelagem C4 do núcleo de Matching e Precificação (convertido dos diagramas Mermaid)" {

    model {
        # --- Atores ---
        passageiro = person "Passageiro" "Solicita corridas pelo app e recebe cotações"
        motorista  = person "Motorista" "Recebe ofertas de corrida e compartilha localização"

        # --- Sistemas externos ---
        maps       = softwareSystem "Provedor de Mapas/Trânsito" "Rotas, ETA e condições de tráfego" "External"
        pagamentos = softwareSystem "Gateway de Pagamentos" "Cobrança e repasses" "External"
        eventos    = softwareSystem "Fontes de Contexto Externo" "Eventos, clima, calendário urbano" "External"
        notif      = softwareSystem "Serviço de Notificações Push" "Entrega de ofertas e avisos" "External"

        # --- Sistema núcleo ---
        core = softwareSystem "Plataforma de Mobilidade - Núcleo de Matching e Pricing" "Casa passageiros e motoristas e precifica corridas em tempo real usando ML" {

            gateway = container "API Gateway / BFF" "Autenticação, rate limiting e roteamento dos apps" "Edge"

            # --- Plano Online (tempo real) ---
            ingest = container "Location Ingestion Service" "Recebe e valida telemetria de localização em alta frequência" "Go" "Online"
            geo    = container "Geo/Supply State Service" "Estado de oferta por célula H3/S2; busca de candidatos próximos" "Go + Redis" "Online"

            pricing = container "Pricing Service" "Cotação e surge pricing por zona" "Java" "Online" {
                quote      = component "Quote Engine" "Calcula a tarifa base estimada (distância, tempo, tarifas)"
                demand     = component "Demand Forecaster Client" "Obtém previsão de demanda por zona/janela do modelo"
                surge      = component "Surge Calculator" "Combina oferta/demanda e elasticidade no multiplicador por zona"
                elasticity = component "Elasticity Model Client" "Consulta sensibilidade ao preço por região/perfil"
                guardrail  = component "Pricing Guardrails" "Aplica limites regulatórios e de negócio (caps, suavização)"
                cache      = component "Surge Cache" "Mantém o surge vigente por célula com TTL curto"
            }

            matching = container "Matching/Dispatch Service" "Geração de candidatos, scoring e alocação" "Java" "Online" {
                orchestrator = component "Match Orchestrator" "Coordena o fluxo de despacho de uma solicitação"
                candidate    = component "Candidate Generator" "Consulta motoristas elegíveis por célula e filtros básicos"
                featureAsm   = component "Feature Assembler" "Monta o vetor de features do par passageiro-motorista"
                scorer       = component "Scoring Engine" "Chama modelos de ETA, cancelamento e compatibilidade e combina em um score"
                optimizer    = component "Allocation Optimizer" "Resolve a alocação ótima (lote) evitando conflitos"
                offer        = component "Offer Manager" "Oferta ao motorista, trata timeout, recusa e re-despacho"
                feedback     = component "Feedback Publisher" "Publica o resultado da oferta para retreino"
            }

            serving    = container "ML Inference Service" "Serve modelos de scoring, cancelamento, ETA e demanda" "Python + ONNX/Triton" "Online"
            trip       = container "Trip/Order Service" "Ciclo de vida da corrida" "Java" "Online"
            featonline = container "Feature Store Online" "Features de baixa latência para inferência" "Redis/DynamoDB" "Online,Database"

            # --- Backbone de eventos ---
            stream = container "Event Backbone" "Log durável de telemetria e eventos de corrida" "Apache Kafka"

            # --- Plano de Dados / Offline ---
            lake        = container "Data Lake" "Histórico bruto e curado para Big Data" "S3 + Parquet/Iceberg" "Offline,Database"
            batch       = container "Processamento Batch/Stream" "ETL, feature engineering e agregações" "Spark/Flink" "Offline"
            featoffline = container "Feature Store Offline" "Features históricas para treino" "Data Warehouse" "Offline,Database"
            training    = container "Pipeline de Treinamento (MLOps)" "Treino, validação e registro de modelos" "Kubeflow/Airflow" "Offline"
            registry    = container "Model Registry" "Versões de modelos aprovados para deploy" "MLflow" "Offline,Database"
        }

        # ===== Relações: Nível 1 (Contexto) =====
        passageiro -> core "Solicita corrida, recebe preço e status"
        motorista  -> core "Envia localização, recebe e aceita ofertas"
        core -> maps "Consulta rotas e ETA" "HTTPS/API"
        core -> pagamentos "Processa pagamento da viagem" "HTTPS/API"
        core -> eventos "Coleta sinais de demanda futura" "HTTPS/API"
        core -> notif "Dispara ofertas e atualizações" "HTTPS/API"

        # ===== Relações: Nível 2 (Containers) =====
        passageiro -> gateway "Solicita corrida e cotação" "HTTPS"
        motorista  -> gateway "Envia localização / recebe ofertas" "HTTPS/WebSocket"

        gateway -> ingest   "Telemetria" "gRPC"
        gateway -> pricing  "Pede cotação" "gRPC"
        gateway -> matching "Solicita corrida" "gRPC"

        ingest   -> stream  "Publica eventos de localização"
        ingest   -> geo     "Atualiza estado de oferta"
        matching -> geo     "Busca candidatos por célula"
        matching -> serving "Pede scores (ETA, cancelamento, score)"
        pricing  -> serving "Pede previsão de demanda/elasticidade"
        serving  -> featonline "Lê features online"
        matching -> trip    "Cria e atualiza a corrida"
        matching -> stream  "Publica resultado da oferta (aceite/recusa)"
        pricing  -> maps    "Consulta trânsito/ETA" "HTTPS"

        stream   -> batch       "Consome eventos"
        batch    -> lake        "Persiste dados curados"
        batch    -> featoffline "Materializa features de treino"
        batch    -> featonline  "Publica features online (online/offline parity)"
        training -> featoffline "Lê features de treino"
        training -> registry    "Registra modelo validado"
        registry -> serving     "Promove/implanta novo modelo"

        # ===== Relações: Nível 3 (Componentes) - Matching/Dispatch =====
        gateway      -> orchestrator "Solicita corrida"
        orchestrator -> candidate    "Pede candidatos"
        candidate    -> geo          "Busca motoristas próximos"
        orchestrator -> featureAsm   "Solicita montagem de features"
        featureAsm   -> pricing      "Obtém contexto de preço/surge"
        orchestrator -> scorer       "Pede scoring dos pares"
        scorer       -> serving      "Inferência dos modelos"
        orchestrator -> optimizer    "Pede alocação ótima"
        optimizer    -> offer        "Aciona oferta ao escolhido"
        offer        -> feedback     "Resultado (aceite/recusa/timeout)"
        feedback     -> stream       "Publica evento de feedback"

        # ===== Relações: Nível 3 (Componentes) - Pricing =====
        gateway -> quote      "Pede cotação"
        quote   -> maps       "Estima distância/tempo"
        quote   -> surge      "Aplica multiplicador vigente"
        surge   -> demand     "Lê demanda prevista"
        surge   -> geo        "Lê oferta atual por célula"
        surge   -> elasticity "Lê elasticidade"
        demand  -> serving    "Inferência de previsão de demanda"
        elasticity -> serving "Inferência de elasticidade"
        surge   -> guardrail  "Valida limites"
        surge   -> cache      "Atualiza/lê surge por zona"
        demand  -> featonline "Lê features de contexto"
    }

    views {
        systemContext core "Contexto" "Diagrama de Contexto - Núcleo de Matching e Precificação" {
            include *
            autolayout lr
        }

        container core "Containers" "Diagrama de Containers - Núcleo de Matching e Pricing" {
            include *
            autolayout lr
        }

        component matching "ComponentesMatching" "Diagrama de Componentes - Matching/Dispatch Service" {
            include *
            autolayout lr
        }

        component pricing "ComponentesPricing" "Diagrama de Componentes - Pricing Service" {
            include *
            autolayout lr
        }

        styles {
            element "Person" {
                shape person
                background #08427b
                color #ffffff
            }
            element "Software System" {
                background #1168bd
                color #ffffff
            }
            element "External" {
                background #999999
                color #ffffff
            }
            element "Container" {
                background #438dd5
                color #ffffff
            }
            element "Online" {
                background #2e8b57
                color #ffffff
            }
            element "Offline" {
                background #b8860b
                color #ffffff
            }
            element "Database" {
                shape cylinder
            }
            element "Component" {
                background #85bbf0
                color #000000
            }
        }
    }
}
