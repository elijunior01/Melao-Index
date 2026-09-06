# Índice Melão (MeI) para MetaTrader 5

[![Licença: MIT](https://img.shields.io/badge/Licença-MIT-green.svg)](https://opensource.org/licenses/MIT)

## 📊 Sobre o projeto

O **Índice Melão (MeI)** é uma métrica de desempenho ajustado ao risco proposta por **Hindemburg Melão Jr.** no artigo:

> *THE MELAO INDEX: A NEW STANDARD FOR RISK-RETURN ANALYSIS, RESOLVING FUNDAMENTAL INCONSISTENCIES IN THE SHARPE RATIO AND RELATED METRICS*

Este projeto implementa o cálculo do MeI em **MQL5**, permitindo analisar o desempenho histórico de estratégias e contas de negociação diretamente no **MetaTrader 5**.

A proposta do Índice Melão é avaliar o desempenho considerando simultaneamente:

- retorno;
- risco representado pelo Maximum Drawdown (MDD);
- transformação do MDD para uma escala compatível com o retorno;
- duração do histórico;
- inflação;
- e, opcionalmente, um benchmark de mercado.

---

## 🎯 Objetivo

Métricas tradicionais como **Sharpe, Sortino, Calmar e MAR** utilizam diferentes formas de relacionar retorno e risco.

O MeI procura reduzir algumas das distorções dessas abordagens utilizando:

1. **Regressão sobre o logaritmo do saldo** para estimar a taxa de crescimento;
2. **MDD** como medida de risco máximo;
3. transformação **MDD*** para colocar risco e retorno em escalas compatíveis;
4. normalização pelo período histórico através de `√T`;
5. ajuste pela inflação.

A formulação principal é:

\[
MeI =
\frac{\ln(1+R)-\ln(1+i)}
{\ln(1+MDD^*)}
\sqrt{T}
\]

onde:

- `R` = retorno anualizado estimado;
- `i` = inflação anual;
- `MDD*` = Maximum Drawdown transformado;
- `T` = período da análise em anos.

---

# 🧮 Como o cálculo funciona

## 1. Retorno

A versão 3.4 utiliza uma **regressão linear de `ln(saldo)` em função do tempo**.

Em vez de considerar somente o primeiro e o último saldo, a regressão utiliza a trajetória histórica disponível para estimar a taxa média de crescimento.

A taxa anualizada é calculada por:

\[
R=e^\beta-1
\]

onde `β` é a inclinação da regressão.

Também existe a possibilidade de aplicar **ponderação exponencial**, dando maior peso às observações mais recentes.

---

## 2. Maximum Drawdown

O MDD representa a maior queda da série de saldo/equity entre um pico e o vale subsequente.

O MDD é então transformado em:

\[
MDD^*=\frac{MDD}{1-MDD}
\]

Essa transformação permite trabalhar com o risco em uma escala sem o limite superior de 100%.

Exemplos:

| MDD | MDD* |
|---:|---:|
| 10% | 0,1111 |
| 20% | 0,2500 |
| 50% | 1,0000 |
| 90% | 9,0000 |

---

## 3. Estimativa dos maiores drawdowns

A versão 3.4 também pode analisar os maiores episódios de drawdown para obter uma estimativa adicional do risco máximo.

O procedimento utiliza:

- os maiores episódios de MDD;
- suas posições percentílicas;
- a transformação em `MDD*`;
- estimativas baseadas na abordagem discutida na Seção VII do artigo.

O objetivo é reduzir a dependência de uma única observação extrema de MDD.

---

## 4. Período histórico

O período analisado é representado por:

\[
T=\text{tempo em anos}
\]

e entra na fórmula como:

\[
\sqrt{T}
\]

Assim, o índice considera a duração do histórico ao comparar retorno e risco.

---

## 5. Inflação

A inflação anual pode ser informada pelo usuário:

```text
0.04 = 4% ao ano
0.00 = sem ajuste
```

Ela é utilizada no numerador:

\[
\ln(1+R)-\ln(1+i)
\]

---

# ⚙️ Características da versão 3.4

A v3.4 foi desenvolvida para tornar a análise mais consistente e transparente.

### Retorno

- Regressão linear sobre `ln(saldo)`;
- série temporal com intervalo configurável;
- opção de ponderação exponencial;
- reconstrução histórica do saldo;
- suporte a períodos históricos encerrados no passado.

### Risco

- cálculo de MDD;
- transformação MDD*;
- identificação de episódios de drawdown;
- estimativa adicional dos maiores riscos através dos episódios de MDD.

### Análise

- cálculo do MeI;
- projeção operacional para 1 ano;
- Profit Factor;
- Recovery Factor;
- Sigma anualizado como métrica auxiliar;
- análise por janelas temporais;
- diagnóstico de estabilidade.

### Benchmark

Permite utilizar opcionalmente um ativo de referência para ajustar a série pelo movimento do mercado.

O recurso pode ser desativado deixando:

```text
benchmark_symbol = ""
```

---

# 📥 Instalação

1. Copie:

```text
IndiceMelao_v3.4.mq5
```

para:

```text
MQL5/Scripts/
```

2. Abra o MetaTrader 5.

3. No **Navegador**, localize:

```text
Scripts → IndiceMelao_v3.4
```

4. Arraste o script para o gráfico.

5. Configure os parâmetros e execute.

---

# ⚙️ Parâmetros

| Parâmetro | Descrição | Padrão |
|---|---|---:|
| `usar_equity_por_deal` | Usa eventos de negociação como série alternativa | `true` |
| `segundos_periodo` | Intervalo da série temporal | `86400` |
| `tempo_inicio` | Início da análise; `0` = automático | `0` |
| `tempo_fim` | Final da análise; `0` = agora | `0` |
| `benchmark_symbol` | Símbolo do benchmark; vazio = desativado | `""` |
| `benchmark_tf` | Timeframe do benchmark | `PERIOD_D1` |
| `topK` | Número de maiores drawdowns analisados | `5` |
| `inflacao_anual` | Inflação anual em decimal | `0.0` |
| `saldo_inicial_manual` | Saldo inicial manual; `0` = automático | `0.0` |
| `ponderar_regressao` | Pondera mais fortemente dados recentes | `false` |
| `fator_ponderacao` | Fator da ponderação exponencial | `0.95` |
| `gravarArquivo` | Salva o relatório em TXT | `true` |
| `abrirArquivoAoFinal` | Abre o relatório automaticamente | `true` |

---

# 📄 Relatório

O script gera um relatório contendo, entre outras informações:

```text
Período analisado
Saldo inicial
Resultado líquido
Retorno do período
Retorno anualizado
MDD
MDD*
Estimativa Bayesiana
MeI
Projeção para 1 ano
Profit Factor
Recovery Factor
Análise por janelas
```

O relatório pode ser salvo na pasta:

```text
MQL5/Files/
```

---

# 📈 Exemplo

Um resultado pode assumir a forma:

```text
R do período              : 108.99%
R anualizado              : 9041.84%
MDD                       : 5.55%
MDD*                      : 0.058809
T                         : 0.0809 anos

MeI                       : 45.3465
```

O valor do MeI deve ser analisado em conjunto com o período, retorno, MDD e metodologia utilizada.

---

# ⚠️ Importante sobre históricos curtos

Períodos curtos podem produzir retornos anualizados extremamente elevados.

Por exemplo, uma estratégia que apresenta crescimento muito forte durante poucas semanas pode resultar em uma taxa anualizada matematicamente enorme.

Isso **não significa que esse crescimento necessariamente será repetido durante um ano inteiro**.

Por esse motivo, o relatório apresenta avisos quando o histórico é curto.

---

# ⚠️ Limitações

O Índice Melão é uma métrica quantitativa e possui limitações.

### MDD

O MDD depende da resolução da série utilizada na análise.

A v3.4 **não deve ser interpretada como um cálculo completo de MDD tick-a-tick da equity flutuante intratrade**.

Uma queda ocorrida enquanto uma posição permanece aberta pode não ser capturada caso não exista um ponto correspondente na série utilizada.

### Estimativa de risco

A estimativa baseada nos maiores drawdowns é uma operacionalização da abordagem apresentada no artigo e não representa uma distribuição universal garantida.

### Períodos curtos

Retornos anualizados e projeções obtidos a partir de históricos muito curtos possuem elevada incerteza.

### Benchmark

O ajuste por benchmark é opcional e sua interpretação depende da natureza da estratégia e do mercado utilizado como referência.

---

# 📚 Fundamentação teórica

O artigo do Índice Melão discute problemas encontrados em métricas tradicionais de desempenho ajustado ao risco e apresenta o MeI como uma alternativa baseada em:

- regressão do crescimento;
- MDD;
- transformação `MDD*`;
- logaritmos;
- inflação;
- normalização temporal.

O artigo também discute a necessidade de considerar a evolução histórica completa em vez de depender exclusivamente dos pontos inicial e final.

---

# 📖 Referência

**Hindemburg Melão Jr.**

*THE MELAO INDEX: A NEW STANDARD FOR RISK-RETURN ANALYSIS, RESOLVING FUNDAMENTAL INCONSISTENCIES IN THE SHARPE RATIO AND RELATED METRICS.*

**SSRN-id 5188185**

[Ver artigo no SSRN](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5188185)

---

# 🤝 Contribuições

Contribuições, sugestões, correções e melhorias são bem-vindas.

Para contribuir, abra uma **Issue** ou envie um **Pull Request**.

---

# 📄 Licença

Este projeto está licenciado sob a **Licença MIT**.

Consulte o arquivo [LICENSE](LICENSE) para obter os termos completos.

---

# ⚠️ Aviso

Este software é fornecido **"como está"**, sem garantias.

O Índice Melão é uma ferramenta de análise quantitativa e **não constitui recomendação de investimento**.

Resultados históricos não garantem resultados futuros.
