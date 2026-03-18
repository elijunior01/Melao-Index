# Índice Melão (MeI) para MetaTrader 5

[![Licença: MIT](https://img.shields.io/badge/Licença-MIT-green.svg)](https://opensource.org/licenses/MIT)

**Calculadora do Índice Melão (MeI)** – um script em MQL5 que implementa o novo padrão para análise de risco-retorno proposto por Hindemburg Melão Jr. no artigo acadêmico *"THE MELAO INDEX: A NEW STANDARD FOR RISK-RETURN ANALYSIS, RESOLVING FUNDAMENTAL INCONSISTENCIES IN THE SHARPE RATIO AND RELATED METRICS"* (SSRN-id5188185).

O Índice Melão corrige distorções presentes em métricas tradicionais como Sharpe, Sortino, Calmar e MAR, ao:
- Usar regressão linear sobre o logaritmo do saldo para estimar o retorno anualizado (eliminando a dependência dos pontos inicial e final).
- Substituir o desvio padrão pelo *maximum drawdown* transformado (`MDD* = MDD/(1-MDD)`) como medida de risco.
- Ajustar a escala entre retorno e risco, permitindo operações aritméticas consistentes.
- Considerar o período de análise (`T`) para normalizar o índice.

## 📥 Instalação

1. Copie o arquivo `IndiceMelao_v3.mq5` para a pasta `MQL5/Scripts/` do seu terminal MetaTrader 5.
2. No MetaTrader, abra o **Navegador**, localize o script em `Scripts` e arraste-o para o gráfico do ativo desejado.
3. Ajuste os parâmetros de entrada conforme necessário e clique em OK.

## ⚙️ Parâmetros de Entrada

| Parâmetro | Descrição | Padrão |
|-----------|-----------|--------|
| `segundos_periodo` | Amostragem da série temporal (em segundos). 86400 = diário; 300 = M5. | 86400 |
| `tempo_inicio` | Data/hora de início da análise. 0 = detecta automaticamente o primeiro deal de trading. | 0 |
| `tempo_fim` | Data/hora de fim. 0 = agora. | 0 |
| `topK` | Número de maiores drawdowns considerados para a média do `MDD*`. | 5 |
| `usarMediaParaMDDestrela` | `true` → usa a média dos topK maiores `MDD*`; `false` → usa o máximo global. | true |
| `inflacao_anual` | Taxa de inflação anual (decimal). Ex: 0.04 = 4% a.a. | 0.0 |
| `saldo_inicial_manual` | Saldo inicial da série (0 = automático). Útil para backtests com capital conhecido. | 0.0 |
| `ponderar_regressao` | Se `true`, aplica ponderação exponencial na regressão (dados recentes com mais peso). | false |
| `fator_ponderacao` | Fator de ponderação (base do exponencial) – usado apenas se `ponderar_regressao = true`. | 0.95 |
| `gravarArquivo` | Salva o relatório em um arquivo `.txt` na pasta `MQL5/Files`. | true |
| `abrirArquivoAoFinal` | Abre automaticamente o arquivo gerado ao final da execução. | true |

## 📊 O que o script calcula?

1. **Série temporal de saldos** – construída a partir dos deals de **compra/venda** (ignora depósitos, retiradas, taxas). Os lucros são agregados em intervalos definidos por `segundos_periodo`.
2. **Retorno anualizado (R)** – obtido pela regressão linear de `ln(saldo)` contra o tempo (em anos). A inclinação da reta é o crescimento logarítmico, convertido em taxa anual: `R = exp(inclinação) - 1`.
3. **Período T** – diferença entre o primeiro e o último ponto da série, em anos.
4. **Drawdowns** – identificação de todos os episódios de queda (pico → vale). Cada drawdown é transformado em `MDD* = MDD/(1-MDD)` (equação 3 do artigo).
5. **MDD* utilizado** – conforme `usarMediaParaMDDestrela`, calcula-se a média dos `topK` maiores `MDD*` ou o máximo global.
6. **Índice Melão (MeI)** – aplica a fórmula:
7. MeI = [ln(1+R) - ln(1+i)] / ln(1+MDD*) * sqrt(T)
8. onde `i` é a inflação anual fornecida.

O relatório final exibe todos esses valores, além do sigma dos log-retornos e detalhes dos drawdowns.

## 📈 Exemplo de Saída
RELATÓRIO DO ÍNDICE MELÃO (MeI)
================================
Início do período: 2020.01.02 00:00
Fim do período: 2025.12.30 23:59
T (anos): 5.997260
Pontos na série: 2192
Deals de trading considerados: 845 (ignorados: 12)
Saldo inicial utilizado: 10000.00

Inclinação da regressão (por ano): 0.152340123456
R anualizado estimado: 0.164534 (16.45%)
Inflação anual i: 0.040000 (4.00%)
Sigma anualizado (log-retornos): 0.187200
Sigma por passo (log-retornos): 0.012345

Episódios de drawdown detectados: 8
Frações originais (MDD) e transformadas (MDD*):
[1] MDD=12.34%, MDD*=0.14080
[2] MDD=8.90%, MDD*=0.09770
...

Usando topK = 5 para calcular MDD*
MDD* global (maior transformado): 0.14080
MDD* utilizado (média dos topK transformados): 0.11234

MeI = 2.345678901234

## 🧠 Fundamentação Teórica

O Índice Melão resolve sete problemas identificados nas métricas clássicas:

1. **Dependência dos pontos inicial/final** → regressão linear no ln(saldo).
2. **Escalas diferentes entre retorno e risco** → transformação `MDD*`.
3. **Crescimento geométrico tratado como aritmético** → uso de logaritmos.
4. **Drawdown cresce com o tempo** → normalização por `sqrt(T)`.
5. **Tratamento inadequado de outliers** → uso do MDD em vez de desvio padrão.
6. **Benchmark "livre de risco" inadequado** → usa inflação como referência de escala.
7. **Distribuições não Gaussianas** → MDD captura caudas pesadas.

Para detalhes completos, consulte o artigo original: [SSRN 5188185](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5188185).

## 🛠️ Contribuições

Contribuições são bem-vindas! Sinta-se à vontade para abrir *issues* ou enviar *pull requests* com melhorias, correções ou traduções.

Antes de contribuir, verifique se o código mantém fidelidade à teoria acadêmica.

## 📄 Licença

Este projeto está licenciado sob a [Licença MIT](LICENSE). Você pode usá-lo livremente, desde que mantenha os créditos aos autores originais e ao artigo de referência.

## ✉️ Contato

- **Autor do código:** Eli Batista de Faria Junior  
  [LinkedIn](https://www.linkedin.com/in/eli-batista-de-faria-j%C3%BAnior-430a5987/)

- **Autor da teoria:** Hindemburg Melão Jr.  
  *THE MELAO INDEX: A NEW STANDARD FOR RISK-RETURN ANALYSIS...* (SSRN-id5188185)

---

**Nota:** Este script é fornecido "como está", sem garantias. Use por sua conta e risco em decisões de investimento reais.
