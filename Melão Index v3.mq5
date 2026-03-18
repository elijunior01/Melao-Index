//+-------------------------------------------------------------------------+
//|                                                     IndiceMelao_v3.mq5 |
//|                                         Índice Melão (MeI) - Calculadora |
//|                                             Eli Batista de Faria Junior |
//|  https://www.linkedin.com/in/eli-batista-de-faria-j%C3%BAnior-430a5987/ |
//+-------------------------------------------------------------------------+
//| Baseado no artigo acadêmico:
//| "THE MELAO INDEX: A NEW STANDARD FOR RISK-RETURN ANALYSIS..."
//| Hindemburg Melão Jr., SSRN-id5188185
//+-------------------------------------------------------------------------+
#property copyright "Eli Batista de Faria Junior"
#property link      "https://www.linkedin.com/in/eli-batista-de-faria-j%C3%BAnior-430a5987/"
#property version   "3.00"
#property strict
#property script_show_inputs

// --- Importação da função ShellExecuteW (abrir arquivo) ---
#import "shell32.dll"
int ShellExecuteW(int hWnd, string lpOperation, string lpFile, string lpParameters, string lpDirectory, int nShowCmd);
#import

// ========== CONSTANTES ==========
#define SEGUNDOS_POR_ANO    (365.25 * 24.0 * 3600.0)
#define EPSILON              1e-8

// ========== INPUTS ==========
input int    segundos_periodo = 86400;              // amostragem (segundos): 86400 = diário
input datetime tempo_inicio = 0;                    // 0 = detecta automaticamente o primeiro deal
input datetime tempo_fim   = 0;                      // 0 = agora
input int    topK = 5;                               // número de maiores drawdowns a considerar
input bool   usarMediaParaMDDestrela = true;         // true: MDD* = média(topK); false: MDD* = máximo
input double inflacao_anual = 0.00;                  // inflação anual (ex: 0.04 = 4%)
input double saldo_inicial_manual = 0.0;             // 0 = automático; >0 força o saldo inicial
input bool   ponderar_regressao = false;              // ponderação exponencial (dados recentes com mais peso)
input double fator_ponderacao = 0.95;                 // usado se ponderar_regressao = true
input bool   gravarArquivo = true;                   // salva resultado em arquivo .txt
input bool   abrirArquivoAoFinal = true;             // abre o arquivo automaticamente

// ========== STRUCT ==========
struct SerieTemporal
{
   datetime tempos[];
   double   saldos[];
   int      tamanho;
};

// ========== FUNÇÕES AUXILIARES ==========

// ln(1+x) seguro – retorna false se x <= -1
bool Ln1pSeguro(double x, double &saida)
{
   if(x <= -1.0) return false;
   saida = MathLog(1.0 + x);
   return true;
}

// Regressão linear (ou ponderada) de y = ln(saldo) vs tempo (anos)
bool RegressaoLinearLnSaldo(const datetime &tempos[], const double &saldos[], int n,
                            double &inclinacao_ano, double &intercepto,
                            bool ponderado = false, double peso_base = 0.95)
{
   if(n < 2) return false;

   double xs[], ys[], pesos[];
   ArrayResize(xs, n);
   ArrayResize(ys, n);
   ArrayResize(pesos, n);

   double soma_pesos = 0.0;
   for(int i = 0; i < n; i++)
   {
      xs[i] = (double)tempos[i] / SEGUNDOS_POR_ANO;  // tempo em anos
      ys[i] = MathLog(saldos[i]);
      if(ponderado)
      {
         // peso exponencial: mais recente = maior peso
         pesos[i] = MathPow(peso_base, n - 1 - i);   // i=0 (mais antigo) tem menor peso
         soma_pesos += pesos[i];
      }
      else
         pesos[i] = 1.0;
   }
   if(ponderado && soma_pesos > 0.0)
   {
      // normaliza pesos para somar 1
      for(int i = 0; i < n; i++) pesos[i] /= soma_pesos;
   }
   else
   {
      for(int i = 0; i < n; i++) pesos[i] = 1.0 / n;
   }

   // Médias ponderadas
   double media_x = 0.0, media_y = 0.0;
   for(int i = 0; i < n; i++)
   {
      media_x += pesos[i] * xs[i];
      media_y += pesos[i] * ys[i];
   }

   double numerador = 0.0, denominador = 0.0;
   for(int i = 0; i < n; i++)
   {
      double dx = xs[i] - media_x;
      double dy = ys[i] - media_y;
      numerador   += pesos[i] * dx * dy;
      denominador += pesos[i] * dx * dx;
   }

   if(denominador == 0.0)
   {
      inclinacao_ano = 0.0;
      intercepto = media_y;
      return true;
   }

   inclinacao_ano = numerador / denominador;
   intercepto = media_y - inclinacao_ano * media_x;
   return true;
}

// Desvio padrão amostral
double DesvioPadraoAmostral(const double &arr[], int n)
{
   if(n <= 1) return 0.0;
   double soma = 0.0;
   for(int i = 0; i < n; i++) soma += arr[i];
   double media = soma / n;
   double acum = 0.0;
   for(int i = 0; i < n; i++) acum += (arr[i] - media) * (arr[i] - media);
   return MathSqrt(acum / (n - 1));
}

// Calcula episódios de drawdown (pico->vale) – retorna frações positivas
void CalcularEpisodiosDrawdown(const double &saldos[], int n, double &dd[], int &quantidade_dd)
{
   quantidade_dd = 0;
   ArrayResize(dd, 0);
   if(n < 2) return;

   double pico = saldos[0];
   double vale = saldos[0];
   bool em_drawdown = false;

   for(int i = 1; i < n; i++)
   {
      double b = saldos[i];
      if(b >= pico)
      {
         if(em_drawdown)
         {
            double magnitude = (pico - vale) / pico;
            if(magnitude > EPSILON)
            {
               ArrayResize(dd, quantidade_dd + 1);
               dd[quantidade_dd] = magnitude;
               quantidade_dd++;
            }
            em_drawdown = false;
         }
         pico = b;
         vale = b;
      }
      else
      {
         em_drawdown = true;
         if(b < vale) vale = b;
      }
   }

   if(em_drawdown)
   {
      double magnitude = (pico - vale) / pico;
      if(magnitude > EPSILON)
      {
         ArrayResize(dd, quantidade_dd + 1);
         dd[quantidade_dd] = magnitude;
         quantidade_dd++;
      }
   }
}

// Transforma MDD (fração) em MDD* = MDD/(1-MDD)  [equação (3) do artigo]
double TransformarParaMDDestrela(double fracao_mdd)
{
   if(fracao_mdd <= 0.0) return 0.0;
   if(fracao_mdd >= 0.999999) return 1e12;  // evita divisão por zero
   return fracao_mdd / (1.0 - fracao_mdd);
}

// Retorna true se o deal deve ser considerado no cálculo do lucro (ignora depósitos/retiradas)
bool DealValido(ulong ticket)
{
   ENUM_DEAL_TYPE tipo = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
   // Considera apenas operações de compra/venda (DEAL_TYPE_BUY, DEAL_TYPE_SELL)
   // Exclui depósitos, retiradas, taxas, etc.
   return (tipo == DEAL_TYPE_BUY || tipo == DEAL_TYPE_SELL);
}

// Constrói série de saldos amostrada a cada 'passo_segundos'
bool ConstruirSerieSaldos(SerieTemporal &st, datetime inicio, datetime fim, int passo_segundos,
                          double saldo_inicial_param, int &total_deals_ignorados)
// use 'saldo_inicial_param' dentro da função no lugar de 'saldo_inicial_manual'
{
   ArrayResize(st.tempos, 0);
   ArrayResize(st.saldos, 0);
   st.tamanho = 0;
   total_deals_ignorados = 0;

   if(passo_segundos <= 0) return false;
   if(fim == 0) fim = TimeCurrent();

   // Se início não fornecido, busca o deal válido mais antigo nos últimos 10 anos
   if(inicio == 0)
   {
      datetime probe_inicio = TimeCurrent() - 10 * 365 * 24 * 3600; // 10 anos
      if(!HistorySelect(probe_inicio, fim))
      {
         Print("HistorySelect(probe) falhou: ", GetLastError());
         return false;
      }

      int total = HistoryDealsTotal();
      if(total <= 0)
      {
         Print("Nenhum deal no histórico");
         return false;
      }

      datetime mais_antigo = (datetime)INT_MAX;
      for(int i = 0; i < total; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(!DealValido(ticket)) continue;  // ignora depósitos na busca do início
         datetime t = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         if(t < mais_antigo) mais_antigo = t;
      }
      if(mais_antigo == (datetime)INT_MAX)
      {
         Print("Nenhum deal de trading encontrado no histórico.");
         return false;
      }
      inicio = mais_antigo;
   }

   if(!HistorySelect(inicio, fim))
   {
      Print("HistorySelect falhou: ", GetLastError());
      return false;
   }

   int total_deals = HistoryDealsTotal();
   if(total_deals <= 0)
   {
      Print("Nenhum deal no intervalo selecionado.");
      return false;
   }

   // Buckets
   int buckets = (int)((fim - inicio) / passo_segundos) + 2;
   double soma_lucro_bucket[];
   ArrayResize(soma_lucro_bucket, buckets);
   ArrayInitialize(soma_lucro_bucket, 0.0);

   double lucro_total = 0.0;
   int deals_considerados = 0;

   // Agrega lucros por bucket, filtrando deals válidos
   for(int i = 0; i < total_deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(!DealValido(ticket))
      {
         total_deals_ignorados++;
         continue;
      }

      datetime t = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      if(t < inicio || t > fim) continue;

      int idx = (int)((t - inicio) / passo_segundos);
      if(idx < 0) idx = 0;
      if(idx >= buckets) idx = buckets - 1;

      double lucro = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      soma_lucro_bucket[idx] += lucro;
      lucro_total += lucro;
      deals_considerados++;
   }

   if(deals_considerados == 0)
   {
      Print("Nenhum deal de trading no intervalo.");
      return false;
   }

   // Estima saldo inicial
   double saldo_base = saldo_inicial_manual;
   if(saldo_base <= 0.0)
   {
      double saldo_atual = AccountInfoDouble(ACCOUNT_BALANCE);
      saldo_base = saldo_atual - lucro_total;
   }

   if(saldo_base <= 0.0)
      saldo_base = EPSILON;

   // Caminha pelos buckets construindo a série
   double saldo_anterior = saldo_base;
   for(int b = 0; b < buckets; b++)
   {
      datetime t_fim = inicio + (datetime)((long)(b + 1) * passo_segundos - 1);
      if(t_fim > fim) t_fim = fim;

      saldo_anterior += soma_lucro_bucket[b];

      ArrayResize(st.tempos, st.tamanho + 1);
      ArrayResize(st.saldos, st.tamanho + 1);

      st.tempos[st.tamanho] = t_fim;
      st.saldos[st.tamanho] = saldo_anterior;
      st.tamanho++;

      if(t_fim >= fim) break;
   }

   if(st.tamanho < 2)
   {
      Print("Série com pontos insuficientes (necessário >=2).");
      return false;
   }

   return true;
}

// Escreve texto em arquivo na pasta Files
void EscreverResultadoEmArquivo(string nome_arquivo, string texto)
{
   int handle = FileOpen(nome_arquivo, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle != INVALID_HANDLE)
   {
      FileWriteString(handle, texto);
      FileClose(handle);
      Print("Resultado gravado em Files\\", nome_arquivo);
   }
   else
      Print("Falha ao abrir arquivo para escrita: ", nome_arquivo, " erro=", GetLastError());
}

// Abre o arquivo com o programa padrão
void AbrirArquivo(string caminho_completo)
{
   int resultado = ShellExecuteW(0, "open", caminho_completo, NULL, NULL, 1);
   if(resultado <= 32)
      Print("Não foi possível abrir o arquivo automaticamente. Código: ", resultado);
}

// ========== PRINCIPAL ==========
void OnStart()
{
   Print("Início do script Índice Melão v3.00.");

   // Validação básica dos inputs
   if(segundos_periodo <= 0)
   {
      Print("Erro: segundos_periodo deve ser positivo.");
      return;
   }
   if(topK < 1)
   {
      Print("Erro: topK deve ser >= 1.");
      return;
   }
   if(inflacao_anual < -0.5 || inflacao_anual > 0.5)
      Print("Aviso: inflação anual fora do intervalo típico (-50% a 50%).");

   datetime fim = (tempo_fim == 0 ? TimeCurrent() : tempo_fim);
   datetime inicio = tempo_inicio;

   int deals_ignorados = 0;
   SerieTemporal st;
   if(!ConstruirSerieSaldos(st, inicio, fim, segundos_periodo, saldo_inicial_manual, deals_ignorados))
   {
      Print("ConstruirSerieSaldos falhou. Abortando.");
      return;
   }

   int n = st.tamanho;
   if(n < 2)
   {
      Print("Número insuficiente de pontos na série.");
      return;
   }

   // Sanitiza saldos (proteção contra logs de valores não positivos)
   for(int i = 0; i < n; i++)
   {
      if(st.saldos[i] <= 0.0)
      {
         PrintFormat("Aviso: saldo no índice %d (tempo %s) não positivo: %f",
                     i, TimeToString(st.tempos[i], TIME_DATE | TIME_MINUTES), st.saldos[i]);
         st.saldos[i] = EPSILON;
      }
   }

   // Regressão sobre ln(saldo)
   double inclinacao_ano = 0.0, intercepto = 0.0;
   if(!RegressaoLinearLnSaldo(st.tempos, st.saldos, n, inclinacao_ano, intercepto,
                               ponderar_regressao, fator_ponderacao))
   {
      Print("Regressão linear falhou.");
      return;
   }

   double R = MathExp(inclinacao_ano) - 1.0; // retorno anualizado

   // Calcula T em anos
   double T = (double)(st.tempos[n - 1] - st.tempos[0]) / SEGUNDOS_POR_ANO;
   if(T <= 0.0) T = 1.0 / 365.25; // fallback

   // Log-retornos por passo (para informação)
   double logretornos[];
   if(n >= 2)
   {
      ArrayResize(logretornos, n - 1);
      for(int i = 1; i < n; i++)
         logretornos[i - 1] = MathLog(st.saldos[i] / st.saldos[i - 1]);
   }

   double sigma_passo = (n >= 2 ? DesvioPadraoAmostral(logretornos, n - 1) : 0.0);
   double periodos_por_ano = SEGUNDOS_POR_ANO / (double)segundos_periodo;
   double sigma_anual = sigma_passo * MathSqrt(periodos_por_ano);

   // Drawdowns
   double dd_frac[];
   int quantidade_dd = 0;
   CalcularEpisodiosDrawdown(st.saldos, n, dd_frac, quantidade_dd);

   double dd_estrela[];
   ArrayResize(dd_estrela, quantidade_dd);
   for(int i = 0; i < quantidade_dd; i++)
      dd_estrela[i] = TransformarParaMDDestrela(dd_frac[i]);

   // Ordena MDD* em ordem decrescente usando ArraySort (mais eficiente)
   if(quantidade_dd > 1)
{
   // Ordenação manual simples (já que topK é pequeno)
   for(int i = 0; i < quantidade_dd - 1; i++)
      for(int j = i + 1; j < quantidade_dd; j++)
         if(dd_estrela[i] < dd_estrela[j])
         {
            double temp = dd_estrela[i];
            dd_estrela[i] = dd_estrela[j];
            dd_estrela[j] = temp;
         }
}

   double MDDestrela_para_MeI = 0.0;
   double global_MDDestrela   = (quantidade_dd > 0) ? dd_estrela[0] : 0.0;

   if(usarMediaParaMDDestrela)
   {
      int usar_k = MathMin(topK, quantidade_dd);
      if(usar_k > 0)
      {
         double soma = 0.0;
         for(int i = 0; i < usar_k; i++)
            soma += dd_estrela[i];
         MDDestrela_para_MeI = soma / usar_k;
      }
      else
         MDDestrela_para_MeI = 0.0;
   }
   else
   {
      MDDestrela_para_MeI = global_MDDestrela;
   }

   // Cálculo do MeI (fórmula 4 do artigo)
   double ln_num, ln_infl, ln_denom;
   bool okNumer = Ln1pSeguro(R, ln_num);
   bool okInfl  = Ln1pSeguro(inflacao_anual, ln_infl);
   bool okDenom = Ln1pSeguro(MDDestrela_para_MeI, ln_denom);

   double MeI = 0.0;
   bool MeI_valido = false;

   if(okNumer && okInfl && okDenom && T > 0.0 && ln_denom != 0.0)
   {
      double numerador = ln_num - ln_infl;
      MeI = numerador / ln_denom * MathSqrt(T);
      MeI_valido = true;
   }

   // Prepara relatório
   string saida;
   saida  = "RELATÓRIO DO ÍNDICE MELÃO (MeI)\n";
   saida += "================================\n";
   saida += "Início do período: " + TimeToString(st.tempos[0], TIME_DATE | TIME_MINUTES) + "\n";
   saida += "Fim do período:    " + TimeToString(st.tempos[n - 1], TIME_DATE | TIME_MINUTES) + "\n";
   saida += StringFormat("T (anos): %.6f\n", T);
   saida += StringFormat("Pontos na série: %d\n", n);
   saida += StringFormat("Deals de trading considerados: %d (ignorados: %d)\n", 
                         HistoryDealsTotal() - deals_ignorados, deals_ignorados);
   saida += StringFormat("Saldo inicial utilizado: %.8f\n", 
                         (saldo_inicial_manual > 0.0 ? saldo_inicial_manual : (AccountInfoDouble(ACCOUNT_BALANCE) - 0.0)));
   saida += "\n";

   saida += StringFormat("Inclinação da regressão (por ano): %.12f\n", inclinacao_ano);
   saida += StringFormat("R anualizado estimado: %.6f (%.2f%%)\n", R, R * 100.0);
   saida += StringFormat("Inflação anual i: %.6f (%.2f%%)\n", inflacao_anual, inflacao_anual * 100.0);
   saida += StringFormat("Sigma anualizado (log-retornos): %.6f\n", sigma_anual);
   saida += StringFormat("Sigma por passo (log-retornos): %.6f\n", sigma_passo);
   saida += "\n";

   saida += StringFormat("Episódios de drawdown detectados: %d\n", quantidade_dd);
   saida += "Frações originais (MDD) e transformadas (MDD*):\n";
   for(int i = 0; i < quantidade_dd; i++)
      saida += StringFormat("  [%d] MDD=%.4f%%, MDD*=%.8f\n", i + 1, dd_frac[i] * 100.0, dd_estrela[i]);

   saida += "\n";
   saida += StringFormat("Usando topK = %d para calcular MDD*\n", topK);
   saida += StringFormat("MDD* global (maior transformado): %.8f\n", global_MDDestrela);

   if(usarMediaParaMDDestrela)
      saida += StringFormat("MDD* utilizado (média dos topK transformados): %.8f\n", MDDestrela_para_MeI);
   else
      saida += StringFormat("MDD* utilizado (máximo global): %.8f\n", MDDestrela_para_MeI);

   saida += "\n";
   if(MeI_valido)
      saida += StringFormat("MeI = %.12f\n", MeI);
   else
      saida += "MeI = inválido (verifique R, inflação ou MDD*; denominador possivelmente zero).\n";

   saida += "\nObservações:\n";
   saida += "- R estimado por regressão linear sobre ln(saldo), conforme artigo.\n";
   saida += "- MDD* = MDD / (1 - MDD) [equação (3)].\n";
   saida += "- MeI = [ln(1+R) - ln(1+i)] / ln(1+MDD*) * sqrt(T) [equação (4)].\n";
   saida += "- Todas as taxas em decimais (ex: 0.10 = 10%).\n";
   if(ponderar_regressao)
      saida += "- Regressão ponderada exponencialmente (dados recentes com maior peso).\n";

   Print(saida);

   // Grava arquivo e tenta abrir
   if(gravarArquivo)
   {
      string nome_arquivo = "IndiceMelao_resultado.txt";
      EscreverResultadoEmArquivo(nome_arquivo, saida);

      string caminho_completo = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\" + nome_arquivo;
      Print("Arquivo salvo: ", caminho_completo);

      if(abrirArquivoAoFinal)
         AbrirArquivo(caminho_completo);
   }

   Print("Script Índice Melão finalizado.");
}
//+------------------------------------------------------------------+