# Índice Melão (MeI) para MetaTrader 5

[![Licença: MIT](https://img.shields.io/badge/Licença-MIT-green.svg)](https://opensource.org/licenses/MIT)

**Calculadora do Índice Melão (MeI)** – um script em MQL5 que implementa a métrica de desempenho proposta por Hindemburg Melão Jr. no artigo *"THE MELAO INDEX: A NEW STANDARD FOR RISK-RETURN ANALYSIS, RESOLVING FUNDAMENTAL INCONSISTENCIES IN THE SHARPE RATIO AND RELATED METRICS"* (SSRN-id5188185).

O Índice Melão corrige distorções presentes em métricas tradicionais (Sharpe, Sortino, Calmar, MAR) ao:

- Usar regressão linear sobre o logaritmo do saldo para estimar o retorno anualizado, eliminando a dependência dos pontos inicial e final.
- Substituir o desvio padrão pelo *maximum drawdown* transformado (`MDD* = MDD/(1-MDD)`) como medida de risco.
- Ajustar a escala entre retorno e risco, permitindo operações aritméticas consistentes.
- Considerar o período de análise (`T`) para normalizar o índice.

Esta versão incorpora melhorias robustez e fidelidade à teoria, incluindo:

- **Estimativa Bayesiana do MDD\*** – projeta o drawdown máximo esperado com base na distribuição dos episódios de perda, evitando subestimação do risco.
- **Série de equity por *deal*** – utiliza a granularidade máxima do MT5 (cada trade fechado gera um ponto), capturando drawdowns intradiários que seriam perdidos em amostragens temporais.
- **Subtração opcional de benchmark** – permite isolar o retorno em excesso da estratégia, removendo o "arrasto" do índice de mercado.

## 📥 Instalação

1. Copie o arquivo `IndiceMelao_v3.2.mq5` para a pasta `MQL5/Scripts/` do seu terminal MetaTrader 5.
2. No MetaTrader, abra o **Navegador**, localize o script em `Scripts` e arraste-o para o gráfico do ativo desejado.
3. Ajuste os parâmetros de entrada conforme necessário e clique em OK.

## ⚙️ Parâmetros de Entrada

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| **Período e Amostragem** |
| `usar_equity_por_deal` | `true` → série por *deal* (resolução máxima); `false` → série temporal com intervalo fixo. | `true` |
| `segundos_periodo` | Amostragem temporal (em segundos). Usado apenas se `usar_equity_por_deal = false`. | `86400` |
| `tempo_inicio` | Data/hora de início da análise. `0` = detecta automaticamente o primeiro *deal* de trading. | `0` |
| `tempo_fim` | Data/hora de fim. `0` = agora. | `0` |
| **Benchmark — Subtração do Mercado** |
| `benchmark_symbol` | Símbolo do benchmark (ex.: `WIN$N`, `IBOV`, `SPX500`). Deixe vazio para desativar. | `""` |
| `benchmark_tf` | *Timeframe* para coleta do preço do benchmark. | `PERIOD_D1` |
| **Parâmetros do MeI** |
| `topK` | Número de maiores drawdowns a considerar na estimativa bayesiana do `MDD*`. | `5` |
| `inflacao_anual` | Taxa de inflação anual (decimal). Ex: `0.04` = 4% a.a. | `0.0` |
| `saldo_inicial_manual` | Saldo inicial da série (`0` = automático). Útil para backtests com capital conhecido. | `0.0` |
| `ponderar_regressao` | Se `true`, aplica ponderação exponencial na regressão (dados recentes com mais peso). | `false` |
| `fator_ponderacao` | Fator de ponderação (base do exponencial) – usado apenas se `ponderar_regressao = true`. | `0.95` |
| **Saída** |
| `gravarArquivo` | Salva o relatório em um arquivo `.txt` na pasta `MQL5/Files`. | `true` |
| `abrirArquivoAoFinal` | Abre automaticamente o arquivo gerado ao final da execução. | `true` |

## 📊 O que o script calcula?

1. **Série de saldos** –  
   - Se `usar_equity_por_deal = true`: cada *deal* de compra/venda gera um ponto (captura drawdowns intradiários).  
   - Caso contrário: os lucros são agregados em intervalos fixos.

2. **Retorno anualizado (R)** – pela regressão linear de `ln(saldo)` contra o tempo.  
   `R = exp(inclinação) - 1`

3. **Período T** – diferença entre o primeiro e o último ponto, em anos.

4. **Drawdowns** – identificação de todos os episódios de queda (pico → vale). Cada drawdown é transformado em `MDD* = MDD/(1-MDD)`.

5. **MDD* Bayesiano** – utilizando os `topK` maiores drawdowns, projeta o drawdown máximo esperado via posições percentílicas e inversa da normal, conforme Seção VII do artigo.

6. **Índice Melão (MeI)** –  
   `MeI = [ln(1+R) - ln(1+i)] / ln(1+MDD*) × √T`  
   onde `i` é a inflação anual.

O relatório final exibe todos os valores calculados, incluindo a tabela da estimativa bayesiana.

## 📈 Exemplo de Saída (v3.2)
RELATÓRIO DO ÍNDICE MELÃO (MeI) v3.2
======================================
Início : 2026.03.01 22:13
Fim : 2026.03.23 00:57
T (anos) : 0.057808
Pontos na série : 2281
Modo de série : Por deal (granularidade máxima)
Deals de trading : 2280
Deals não-trading : 0
Saldo base estimado : 1000.00000000
Benchmark : desativado

R anualizado (regressão) : 244.964096 (24496.4096% a.a.)
Inflação anual : 0.000000 (0.0000% a.a.)
Sigma anualizado : 0.837241
Períodos/ano usados : 39440.73

Episódios de drawdown : 68
MDD medido (maior) : 13.2105% → MDD* = 0.15221265

--- Estimativa Bayesiana do MDD* ---
n_episodios=68 | media(MDD*)=0.012195 | z(k=1)=2.1837
k MDD*_k p_k z_k sigma_k est_k
1 0.152213 0.9855 2.1837 0.064120 0.152213 ← novo máx
2 0.082993 0.9710 1.8959 0.037342 0.093739
3 0.082849 0.9565 1.7117 0.041278 0.102333
4 0.074330 0.9420 1.5720 0.039525 0.098506
5 0.065703 0.9275 1.4577 0.036707 0.092352

MDD* Bayesiano final = 0.15221265 (MDD equivalente = 13.2105%)

MeI = 9.342125312790 <<<


## 🧠 Fundamentação Teórica

O Índice Melão resolve sete problemas identificados nas métricas clássicas:

1. **Dependência dos pontos inicial/final** → regressão linear no ln(saldo).
2. **Escalas diferentes entre retorno e risco** → transformação `MDD*`.
3. **Crescimento geométrico tratado como aritmético** → uso de logaritmos.
4. **Drawdown cresce com o tempo** → normalização por `√T`.
5. **Tratamento inadequado de outliers** → uso do MDD em vez de desvio padrão.
6. **Benchmark "livre de risco" inadequado** → usa inflação como referência de escala.
7. **Distribuições não Gaussianas** → MDD captura caudas pesadas.

Para detalhes completos, consulte o artigo original: [SSRN 5188185](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5188185).

## 🛠️ Contribuições

Contribuições são bem-vindas! Abra *issues* ou envie *pull requests* com melhorias, correções ou traduções, mantendo a fidelidade à teoria acadêmica.

## 📄 Licença

Este projeto está licenciado sob a [Licença MIT](LICENSE). Você pode usá-lo livremente, desde que mantenha os créditos aos autores originais e ao artigo de referência.

## ✉️ Contato

- **Autor do código:** Eli Batista de Faria Junior  
  [LinkedIn](https://www.linkedin.com/in/eli-batista-de-faria-j%C3%BAnior-430a5987/)

- **Autor da teoria:** Hindemburg Melão Jr.  
  *THE MELAO INDEX: A NEW STANDARD FOR RISK-RETURN ANALYSIS...* (SSRN-id5188185)

---

**Nota:** Este script é fornecido "como está", sem garantias. Use por sua conta e risco em decisões de investimento reais.
