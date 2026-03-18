//+-------------------------------------------------------------------------+
//|                                                             Melao Index |
//|                                             Eli Batista de Faria Junior |
//|  https://www.linkedin.com/in/eli-batista-de-faria-j%C3%BAnior-430a5987/ |
//+-------------------------------------------------------------------------+
#property copyright "Eli Batista de Faria Junior"
#property link      "https://www.linkedin.com/in/eli-batista-de-faria-j%C3%BAnior-430a5987/"
#property version   "2.01"
#property script_show_inputs

// --- Importação direta da função ShellExecuteW ---
#import "shell32.dll"
int ShellExecuteW(int hWnd, string lpOperation, string lpFile, string lpParameters, string lpDirectory, int nShowCmd);
#import

// ========== INPUTS ==========
input int    segundos_periodo = 86400;   // amostragem em segundos (86400 = diário). Use 300 para M5
input datetime tempo_inicio = 0;         // 0 -> detecta automaticamente o primeiro histórico disponível
input datetime tempo_fim   = 0;          // 0 -> agora
input int    topK = 5;                   // número k de maiores drawdowns a considerar
input bool   usarMediaParaMDDestrela = true; // true -> MDD* = média(topK); false -> MDD* = máximo global (ou máximo dos topK)
input double inflacao_anual = 0.00;      // i (ex: 0.05 = 5% ao ano). Ajuste conforme necessário
input bool   gravarArquivo = true;       // escreve resultado em MQL5/Files
input bool   abrirArquivoAoFinal = true; // abre automaticamente o arquivo .txt ao final

// ========== STRUCT ==========
struct SerieTemporal
  {
   datetime          tempos[];
   double            saldos[];
   int               tamanho;
  };

// ========== FUNÇÕES AUXILIARES ==========
// Ln(1+x) seguro. Retorna false se x <= -1.
bool Ln1pSeguro(double x, double &saida)
  {
   if(x <= -1.0)
      return false;
   saida = MathLog(1.0 + x);
   return true;
  }

// Regressão linear de y = ln(saldo) vs tempo (em anos)
bool RegressaoLinearLnSaldo(const datetime &tempos[], const double &saldos[], int n, double &inclinacao_ano, double &intercepto)
  {
   if(n < 2)
      return false;
   double soma_x = 0.0, soma_y = 0.0;
   double xs[];
   ArrayResize(xs, n);
   for(int i = 0; i < n; i++)
     {
      xs[i] = (double)tempos[i] / (365.25 * 24.0 * 3600.0); // anos
      soma_y += MathLog(saldos[i]);
      soma_x += xs[i];
     }
   double media_x = soma_x / n;
   double media_y = soma_y / n;
   double numerador = 0.0, denominador = 0.0;
   for(int i = 0; i < n; i++)
     {
      double y = MathLog(saldos[i]);
      numerador += (xs[i] - media_x) * (y - media_y);
      denominador += (xs[i] - media_x) * (xs[i] - media_x);
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
   if(n <= 1)
      return 0.0;
   double soma = 0.0;
   for(int i = 0; i < n; i++)
      soma += arr[i];
   double media = soma / n;
   double acum = 0.0;
   for(int i = 0; i < n; i++)
      acum += (arr[i] - media) * (arr[i] - media);
   return MathSqrt(acum / (n - 1));
  }

// Calcula episódios de drawdown (pico->vale) e retorna array de magnitudes (fração positiva, ex: 0.25 = 25%)
void CalcularEpisodiosDrawdown(const double &saldos[], int n, double &dd[], int &quantidade_dd)
  {
   quantidade_dd = 0;
   ArrayResize(dd, 0);
   if(n < 2)
      return;
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
            double magnitude = (pico - vale) / pico; // positiva
            if(magnitude > 0.0)
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
         if(b < vale)
            vale = b;
        }
     }
   if(em_drawdown)
     {
      double magnitude = (pico - vale) / pico;
      if(magnitude > 0.0)
        {
         ArrayResize(dd, quantidade_dd + 1);
         dd[quantidade_dd] = magnitude;
         quantidade_dd++;
        }
     }
  }

// Ordena array decrescente (bubble simples, topK pequeno)
void OrdenarDesc(double &arr[], int n)
  {
   if(n < 2)
      return;
   for(int i = 0; i < n - 1; i++)
      for(int j = 0; j < n - i - 1; j++)
         if(arr[j] < arr[j+1])
           {
            double t = arr[j];
            arr[j] = arr[j+1];
            arr[j+1] = t;
           }
  }

// Transforma MDD (fração) em MDD* = MDD/(1-MDD)
double TransformarParaMDDestrela(double fracao_mdd)
  {
   if(fracao_mdd <= 0.0)
      return 0.0;
   if(fracao_mdd >= 1.0)
     {
      // Para evitar divisão por zero, assume perda total: retorna um valor muito grande
      return 1e12;
     }
   return fracao_mdd / (1.0 - fracao_mdd);
  }

// Constrói série de saldos amostrada a cada 'segundos_periodo' entre tempo_inicio e tempo_fim
bool ConstruirSerieSaldos(SerieTemporal &st, datetime inicio, datetime fim, int passo_segundos)
  {
   ArrayResize(st.tempos, 0);
   ArrayResize(st.saldos, 0);
   st.tamanho = 0;
   if(passo_segundos <= 0)
      return false;
   if(fim == 0)
      fim = TimeCurrent();
// Se início não fornecido, busca o deal mais antigo nos últimos 10 anos
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
         long lt = (long)HistoryDealGetInteger(ticket, DEAL_TIME);
         datetime t = (datetime)lt;
         if(t < mais_antigo)
            mais_antigo = t;
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
// buckets
   int buckets = (int)((fim - inicio) / passo_segundos) + 2;
   double soma_lucro_bucket[];
   ArrayResize(soma_lucro_bucket, buckets);
   for(int b=0; b<buckets; b++)
      soma_lucro_bucket[b] = 0.0;
   double lucro_total = 0.0;
// Agrega lucros por bucket
   for(int i = 0; i < total_deals; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      long lt = (long)HistoryDealGetInteger(ticket, DEAL_TIME);
      datetime t = (datetime)lt;
      if(t < inicio || t > fim)
         continue;
      int idx = (int)((t - inicio) / passo_segundos);
      if(idx < 0)
         idx = 0;
      if(idx >= buckets)
         idx = buckets - 1;
      double lucro = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      soma_lucro_bucket[idx] += lucro;
      lucro_total += lucro;
     }
// Estima saldo inicial
   double saldo_atual = AccountInfoDouble(ACCOUNT_BALANCE);
   double saldo_inicial = saldo_atual - lucro_total;
   if(saldo_inicial <= 0.0)
      saldo_inicial = 1e-8; // evita log de zero
// Caminha pelos buckets construindo a série
   double saldo_anterior = saldo_inicial;
   for(int b=0; b<buckets; b++)
     {
      datetime t_fim = inicio + datetime((long)(b+1) * passo_segundos - 1);
      if(t_fim > fim)
         t_fim = fim;
      saldo_anterior = saldo_anterior + soma_lucro_bucket[b];
      ArrayResize(st.tempos, st.tamanho + 1);
      ArrayResize(st.saldos, st.tamanho + 1);
      st.tempos[st.tamanho] = t_fim;
      st.saldos[st.tamanho] = saldo_anterior;
      st.tamanho++;
      if(t_fim >= fim)
         break;
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
   int handle = FileOpen(nome_arquivo, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(handle != INVALID_HANDLE)
     {
      FileWriteString(handle, texto);
      FileClose(handle);
      Print("Resultado gravado em Files\\", nome_arquivo);
     }
   else
     {
      Print("Falha ao abrir arquivo para escrita: ", nome_arquivo, " erro=", GetLastError());
     }
  }

// Tenta abrir o arquivo com o programa padrão (Windows)
void AbrirArquivo(string caminho_completo)
  {
// ShellExecuteW recebe strings diretamente (MQL5 strings são Unicode)
   int resultado = ShellExecuteW(0, "open", caminho_completo, NULL, NULL, 1); // 1 = SW_SHOWNORMAL
   if(resultado <= 32)
      Print("Não foi possível abrir o arquivo automaticamente. Código: ", resultado);
  }

//============= PRINCIPAL =============
void OnStart()
  {
   Print("Início do script Índice Melão v2.");
   datetime fim = tempo_fim==0 ? TimeCurrent() : tempo_fim;
   datetime inicio = tempo_inicio;
   SerieTemporal st;
   if(!ConstruirSerieSaldos(st, inicio, fim, segundos_periodo))
     {
      Print("ConstruirSerieSaldos falhou. Abortando.");
      return;
     }
   int n = st.tamanho;
// Sanitiza saldos
   for(int i=0; i<n; i++)
     {
      if(st.saldos[i] <= 0.0)
        {
         PrintFormat("Aviso: saldo no índice %d (tempo %s) não positivo: %f", i, TimeToString(st.tempos[i]), st.saldos[i]);
         if(st.saldos[i] <= 0.0)
            st.saldos[i] = 1e-8;
        }
     }
// Regressão sobre ln(saldo)
   double inclinacao_ano = 0.0, intercepto = 0.0;
   if(!RegressaoLinearLnSaldo(st.tempos, st.saldos, n, inclinacao_ano, intercepto))
     {
      Print("Regressão linear falhou.");
      return;
     }
   double R = MathExp(inclinacao_ano) - 1.0; // retorno anualizado
// Calcula T em anos
   double T = (double)(st.tempos[n-1] - st.tempos[0]) / (365.25 * 24.0 * 3600.0);
   if(T <= 0.0)
      T = 1.0/365.25;
// Calcula log-retornos por passo (para informação, não usado no MeI)
   double logretornos[];
   ArrayResize(logretornos, n-1);
   for(int i=1; i<n; i++)
      logretornos[i-1] = MathLog(st.saldos[i] / st.saldos[i-1]);
   double sigma_passo = DesvioPadraoAmostral(logretornos, n-1);
   double periodos_por_ano = (365.25 * 24.0 * 3600.0) / (double)segundos_periodo;
   double sigma_anual = sigma_passo * MathSqrt(periodos_por_ano);
// Calcula episódios de drawdown (frações)
   double dd_frac[];
   int quantidade_dd = 0;
   CalcularEpisodiosDrawdown(st.saldos, n, dd_frac, quantidade_dd);
// Transforma cada fração em MDD*
   double dd_estrela[];
   ArrayResize(dd_estrela, quantidade_dd);
   for(int i=0; i<quantidade_dd; i++)
      dd_estrela[i] = TransformarParaMDDestrela(dd_frac[i]);
// Ordena os MDD* em ordem decrescente
   if(quantidade_dd > 1)
      OrdenarDesc(dd_estrela, quantidade_dd);
// Define o MDD* a ser usado no índice
   double MDDestrela_para_MeI = 0.0;
   double global_MDDestrela = (quantidade_dd > 0) ? dd_estrela[0] : 0.0;
   if(usarMediaParaMDDestrela)
     {
      // Média dos topK maiores MDD*
      int usar_k = MathMin(topK, quantidade_dd);
      if(usar_k > 0)
        {
         double soma = 0.0;
         for(int i=0; i<usar_k; i++)
            soma += dd_estrela[i];
         MDDestrela_para_MeI = soma / usar_k;
        }
      else
         MDDestrela_para_MeI = 0.0;
     }
   else
     {
      // Máximo global (ou máximo dos topK, que é o mesmo)
      MDDestrela_para_MeI = global_MDDestrela;
     }
// Calcula MeI = (ln(1+R) - ln(1+inflacao)) / ln(1+MDD*) * sqrt(T)
   double ln_num, ln_infl, ln_denom;
   bool okNumer = Ln1pSeguro(R, ln_num);
   bool okInfl  = Ln1pSeguro(inflacao_anual, ln_infl);
   bool okDenom = Ln1pSeguro(MDDestrela_para_MeI, ln_denom); // note: ln(1+MDD*)
   double MeI = 0.0;
   bool MeI_valido = false;
   if(okNumer && okInfl && okDenom && T > 0.0 && ln_denom != 0.0)
     {
      double numerador = ln_num - ln_infl;
      MeI = numerador / ln_denom * MathSqrt(T);
      MeI_valido = true;
     }
// Prepara saída de texto
   string saida;
   saida += "RELATÓRIO DO ÍNDICE MELÃO (MeI)\n";
   saida += "================================\n";
   saida += "Início do período: " + TimeToString(st.tempos[0]) + "\n";
   saida += "Fim do período:    " + TimeToString(st.tempos[n-1]) + "\n";
   saida += StringFormat("T (anos): %.6f\n", T);
   saida += StringFormat("Pontos na série: %d\n\n", n);
   saida += StringFormat("Inclinação da regressão (por ano): %.12f\n", inclinacao_ano);
   saida += StringFormat("R anualizado estimado: %.6f (%.2f%%)\n", R, R*100.0);
   saida += StringFormat("Inflação anual i: %.6f (%.2f%%)\n", inflacao_anual, inflacao_anual*100.0);
   saida += StringFormat("Sigma anualizado (log-retornos): %.6f\n\n", sigma_anual);
// Drawdowns (exibe frações originais e transformadas)
   saida += StringFormat("Episódios de drawdown detectados: %d\n", quantidade_dd);
   saida += "Frações originais (MDD) e transformadas (MDD*):\n";
   for(int i=0; i<quantidade_dd; i++)
      saida += StringFormat("  [%d] MDD=%.4f%%, MDD*=%.4f\n", i+1, dd_frac[i]*100.0, dd_estrela[i]);
   saida += "\n";
   saida += StringFormat("Usando topK = %d para calcular MDD*\n", topK);
   saida += StringFormat("MDD* global (maior transformado): %.6f\n", global_MDDestrela);
   if(usarMediaParaMDDestrela)
      saida += StringFormat("MDD* utilizado (média dos topK transformados): %.6f\n", MDDestrela_para_MeI);
   else
      saida += StringFormat("MDD* utilizado (máximo global): %.6f\n", MDDestrela_para_MeI);
   saida += "\n";
   if(MeI_valido)
      saida += StringFormat("MeI = %.8f\n", MeI);
   else
      saida += "MeI = inválido (verifique R, inflação ou MDD*; denominador possivelmente zero).\n";
   saida += "\nObservações:\n";
   saida += "- R estimado por regressão sobre ln(saldo) (robusto a pontos extremos).\n";
   saida += "- MDD* = MDD / (1 - MDD) conforme equação (3) do artigo.\n";
   saida += "- Todas as taxas estão em decimais (ex: 0.10 = 10%).\n";
// Exibe no log
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
