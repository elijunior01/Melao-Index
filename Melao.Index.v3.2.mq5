//+-------------------------------------------------------------------------+
//|                                                    IndiceMelao_v3.2.mq5 |
//|                        Índice Melão (MeI) — Calculadora v3.2            |
//|               Correções baseadas no artigo SSRN-5188185                 |
//|                                                                         |
//| CORREÇÕES IMPLEMENTADAS (comparado ao v3.1):                            |
//|                                                                         |
//| [FIX 1+4] Estimativa BAYESIANA do MDD* (Seção VII do artigo).           |
//|           O v3.1 usava média simples dos top-K MDDs, o que o artigo     |
//|           explicitamente condena. Agora: para cada k-ésimo drawdown     |
//|           calcula-se o desvio-padrão implícito via posição percentílica |
//|           e projeta-se qual seria o MDD* global com esse desvio.        |
//|           O resultado é o MÁXIMO entre todas essas estimativas.         |
//|                                                                         |
//| [FIX 2]   Série de equity construída POR DEAL, não por bucket temporal. |
//|           Cada deal de trading gera um ponto → granularidade máxima     |
//|           disponível no MT5 para captura do MDD real (Seção VII).       |
//|                                                                         |
//| [FIX 3]   Subtração OPCIONAL do benchmark/índice de mercado (Seção IX). |
//|           O retorno em excesso exc[i] = bal[i] × (bench[0]/bench[i])   |
//|           remove o "arrasto" do mercado, medindo o movimento próprio    |
//|           da estratégia conforme recomendado pelo artigo.               |
//+-------------------------------------------------------------------------+
#property copyright "Eli Batista de Faria Junior"
#property link      "https://www.linkedin.com/in/eli-batista-de-faria-j%C3%BAnior-430a5987/"
#property version   "3.2"
#property strict
#property script_show_inputs

#import "shell32.dll"
int ShellExecuteW(int hWnd,string lpOperation,string lpFile,
                  string lpParameters,string lpDirectory,int nShowCmd);
#import

#define SEGUNDOS_POR_ANO  (365.25*24.0*3600.0)
#define EPSILON           1e-8

//=============================================================================
// INPUTS
//=============================================================================
input group           "=== Período e Amostragem ==="
input int             segundos_periodo     = 86400; // Usado SOMENTE se usar_equity_por_deal=false
input bool            usar_equity_por_deal = true;  // [FIX 2] true=por deal | false=temporal
input datetime        tempo_inicio         = 0;     // 0 = detecta o 1º deal automaticamente
input datetime        tempo_fim            = 0;     // 0 = agora

input group           "=== Benchmark — Subtração do Mercado [FIX 3] ==="
input string          benchmark_symbol     = "";    // Ex.: "WIN$N","IBOV","SPX500" | ""=desativado
input ENUM_TIMEFRAMES benchmark_tf         = PERIOD_D1;

input group           "=== Parâmetros do MeI ==="
input int             topK                 = 5;    // Qtd de drawdowns p/ estimativa bayesiana [FIX 1+4]
input double          inflacao_anual       = 0.00; // 0.045 = 4,5% a.a.
input double          saldo_inicial_manual = 0.0;  // 0 = automático
input bool            ponderar_regressao   = false;
input double          fator_ponderacao     = 0.95;

input group           "=== Saída ==="
input bool            gravarArquivo        = true;
input bool            abrirArquivoAoFinal  = true;

//=============================================================================
// STRUCTS
//=============================================================================
struct SerieTemporal
{
   datetime tempos[];
   double   saldos[];
   int      tamanho;
};

//=============================================================================
// [FIX 1+4] INVERSA DA NORMAL PADRÃO
// Algoritmo de Peter Acklam — precisão ~1.15e-9.
// Necessário para converter posições percentílicas em z-scores na estimativa
// bayesiana do MDD* (método da Seção VII do artigo).
//=============================================================================
double InvNormalCDF(double p)
{
   if(p <= 0.0) return -1e12;
   if(p >= 1.0) return  1e12;

   // Coeficientes da aproximação racional de Acklam
   static double a1 = -3.969683028665376e+01;
   static double a2 =  2.209460984245205e+02;
   static double a3 = -2.759285104469687e+02;
   static double a4 =  1.383577518672690e+02;
   static double a5 = -3.066479806614716e+01;
   static double a6 =  2.506628277459239e+00;

   static double b1 = -5.447609879822406e+01;
   static double b2 =  1.615858368580409e+02;
   static double b3 = -1.556989798598866e+02;
   static double b4 =  6.680131188771972e+01;
   static double b5 = -1.328068155288572e+01;

   static double c1 = -7.784894002430293e-03;
   static double c2 = -3.223964580411365e-01;
   static double c3 = -2.400758277161838e+00;
   static double c4 = -2.549732539343734e+00;
   static double c5 =  4.374664141464968e+00;
   static double c6 =  2.938163982698783e+00;

   static double d1 =  7.784695709041462e-03;
   static double d2 =  3.224671290700398e-01;
   static double d3 =  2.445134137142996e+00;
   static double d4 =  3.754408661907416e+00;

   double p_low  = 0.02425;
   double p_high = 1.0 - p_low;
   double q, r, x;

   if(p < p_low)
   {
      q = MathSqrt(-2.0*MathLog(p));
      x = (((((c1*q+c2)*q+c3)*q+c4)*q+c5)*q+c6) /
           ((((d1*q+d2)*q+d3)*q+d4)*q+1.0);
   }
   else if(p <= p_high)
   {
      q = p - 0.5;
      r = q*q;
      x = (((((a1*r+a2)*r+a3)*r+a4)*r+a5)*r+a6)*q /
           (((((b1*r+b2)*r+b3)*r+b4)*r+b5)*r+1.0);
   }
   else
   {
      q = MathSqrt(-2.0*MathLog(1.0-p));
      x = -(((((c1*q+c2)*q+c3)*q+c4)*q+c5)*q+c6) /
            ((((d1*q+d2)*q+d3)*q+d4)*q+1.0);
   }
   return x;
}

//=============================================================================
// FUNÇÕES AUXILIARES
//=============================================================================

bool Ln1pSeguro(double x, double &saida)
{
   if(x <= -1.0) return false;
   saida = MathLog(1.0+x);
   return true;
}

// Regressão linear (ou ponderada) de ln(saldo) vs. tempo em anos.
// Inclinação = ln(1+R), conforme Seção III do artigo.
bool RegressaoLinearLnSaldo(const datetime &tempos[], const double &saldos[], int n,
                            double &inclinacao_ano, double &intercepto,
                            bool ponderado = false, double peso_base = 0.95)
{
   if(n < 2) return false;

   double xs[], ys[], pesos[];
   ArrayResize(xs,n); ArrayResize(ys,n); ArrayResize(pesos,n);
   double t0 = (double)tempos[0], soma_p = 0.0;

   for(int i=0; i<n; i++)
   {
      xs[i]    = ((double)tempos[i] - t0) / SEGUNDOS_POR_ANO;
      ys[i]    = MathLog(saldos[i]);
      pesos[i] = ponderado ? MathPow(peso_base, n-1-i) : 1.0;
      soma_p  += pesos[i];
   }
   if(soma_p > 0.0)
      for(int i=0; i<n; i++) pesos[i] /= soma_p;
   else
      for(int i=0; i<n; i++) pesos[i] = 1.0/n;

   double mx=0.0, my=0.0;
   for(int i=0; i<n; i++) { mx += pesos[i]*xs[i]; my += pesos[i]*ys[i]; }

   double num=0.0, den=0.0;
   for(int i=0; i<n; i++)
   {
      double dx = xs[i]-mx;
      num += pesos[i]*dx*(ys[i]-my);
      den += pesos[i]*dx*dx;
   }
   if(MathAbs(den) < EPSILON) { inclinacao_ano=0.0; intercepto=my; return true; }
   inclinacao_ano = num/den;
   intercepto     = my - inclinacao_ano*mx;
   return true;
}

double DesvioPadraoAmostral(const double &arr[], int n)
{
   if(n <= 1) return 0.0;
   double soma=0.0;
   for(int i=0; i<n; i++) soma += arr[i];
   double media = soma/n, acum=0.0;
   for(int i=0; i<n; i++) acum += (arr[i]-media)*(arr[i]-media);
   return MathSqrt(acum/(n-1));
}

void OrdenarDescendente(double &arr[], int n)
{
   for(int i=0; i<n-1; i++)
      for(int j=0; j<n-i-1; j++)
         if(arr[j] < arr[j+1]) { double tmp=arr[j]; arr[j]=arr[j+1]; arr[j+1]=tmp; }
}

// Detecta episódios pico→vale completos (retorna ao high-water mark entre cada par).
void CalcularEpisodiosDrawdown(const double &saldos[], int n, double &dd[], int &qtd)
{
   qtd=0; ArrayResize(dd,0);
   if(n<2) return;
   double pico=saldos[0], vale=saldos[0];
   bool em_dd=false;

   for(int i=1; i<n; i++)
   {
      if(saldos[i] >= pico)
      {
         if(em_dd)
         {
            double mag = (pico-vale)/pico;
            if(mag > EPSILON) { ArrayResize(dd,qtd+1); dd[qtd++]=mag; }
            em_dd=false;
         }
         pico=saldos[i]; vale=saldos[i];
      }
      else
      {
         em_dd=true;
         if(saldos[i] < vale) vale=saldos[i];
      }
   }
   // Drawdown ainda aberto ao final da série
   if(em_dd)
   {
      double mag=(pico-vale)/pico;
      if(mag>EPSILON) { ArrayResize(dd,qtd+1); dd[qtd++]=mag; }
   }
}

// MDD* = MDD / (1 - MDD)   [equação 3 do artigo]
double TransformarParaMDDestrela(double f)
{
   if(f <= 0.0)       return 0.0;
   if(f >= 0.999999)  return 1e12;
   return f/(1.0-f);
}

bool DealEhTrading(ulong ticket)
{
   ENUM_DEAL_TYPE t = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
   return (t == DEAL_TYPE_BUY || t == DEAL_TYPE_SELL);
}

//=============================================================================
// [FIX 1+4] ESTIMATIVA BAYESIANA DO MDD*   (Seção VII do artigo)
//
// PROBLEMA DO v3.1: usava média simples dos top-K MDDs*.
// O artigo diz explicitamente: "using the average of the MDDs does not solve
// the problem. In fact it makes the problem WORSE" (Seção VII).
//
// SOLUÇÃO CORRETA (conforme Seção VII):
//   Para cada k-ésimo maior drawdown:
//   1. Posição percentílica: p_k = (n_dd - k + 1) / (n_dd + 1)
//      [fórmula de Blom/Hazen; verifica com o exemplo do artigo:
//       n=100, k=1 → 100/101 ≈ 0.99 → z≈2.33  ✓
//       n=100, k=2 →  99/101 ≈ 0.98 → z≈2.05  ✓]
//   2. z_k = InvNormalCDF(p_k)
//   3. sigma_k = (MDD*_k - media_MDD*) / z_k
//   4. Estimativa do global: est_k = media + z_1 × sigma_k
//      onde z_1 = InvNormalCDF(n_dd / (n_dd+1))
//   5. MDD* Bayesiano = MAX de todas as est_k
//      (o artigo: "consider the largest of them... better estimate of max risk")
//=============================================================================
double MDDStarBayesiano(const double &dd_frac[], int n_dd, int k_max, string &detalhe)
{
   detalhe = "";
   if(n_dd <= 0) { detalhe="Nenhum episódio de drawdown detectado.\n"; return 0.0; }

   // 1. Converter para MDD* e ordenar decrescente
   double mdd_star[];
   ArrayResize(mdd_star, n_dd);
   for(int i=0; i<n_dd; i++) mdd_star[i] = TransformarParaMDDestrela(dd_frac[i]);
   OrdenarDescendente(mdd_star, n_dd);

   // 2. Média de todos os MDD*
   double media=0.0;
   for(int i=0; i<n_dd; i++) media += mdd_star[i];
   media /= n_dd;

   // 3. z-score para a posição do maior (k=1) — usado para todas as estimativas
   double p1 = (double)n_dd / (double)(n_dd+1);
   double z1 = InvNormalCDF(p1);

   int usar_k = (k_max < n_dd) ? k_max : n_dd;

   // Começa com o MDD* medido como piso (est_k=1 sempre retorna mdd_star[0])
   double max_est = mdd_star[0];

   detalhe += StringFormat("n_episodios=%d | media(MDD*)=%.6f | z(k=1)=%.4f\n",
                           n_dd, media, z1);
   detalhe += "k      MDD*_k       p_k     z_k     sigma_k      est_k\n";
   detalhe += "-----  -----------  ------  ------  -----------  -----------\n";

   for(int k=1; k<=usar_k; k++)
   {
      double p_k = (double)(n_dd - k + 1) / (double)(n_dd + 1);
      double z_k = InvNormalCDF(p_k);

      // Ignora k onde mdd_star < media (z_k ≤ 0 ou sigma negativo)
      if(z_k <= EPSILON)
      {
         detalhe += StringFormat("k=%-4d ignorado (z_k=%.4f ≤ 0, MDD*_k abaixo da média)\n",
                                 k, z_k);
         continue;
      }

      double sigma_k = (mdd_star[k-1] - media) / z_k;
      if(sigma_k <= 0.0)
      {
         detalhe += StringFormat("k=%-4d ignorado (sigma_k=%.6f ≤ 0)\n", k, sigma_k);
         continue;
      }

      double est_k = media + z1 * sigma_k;
      bool novo_max = (est_k > max_est);
      if(novo_max) max_est = est_k;

      detalhe += StringFormat("%-5d  %-11.6f  %-6.4f  %-6.4f  %-11.6f  %-11.6f%s\n",
                              k, mdd_star[k-1], p_k, z_k, sigma_k, est_k,
                              novo_max ? " ← novo máx" : "");
   }
   detalhe += StringFormat("\nMDD* Bayesiano final = %.8f  (MDD equivalente = %.4f%%)\n",
                           max_est, max_est/(1.0+max_est)*100.0);
   return max_est;
}

//=============================================================================
// [FIX 2] CONSTRUÇÃO DA SÉRIE POR DEAL   (Seção VII do artigo)
//
// PROBLEMA DO v3.1: buckets temporais (ex.: diário) podem mascarar drawdowns
// intradiários ou entre dias sem trades, subestimando o MDD real.
// O artigo diz: "the true MDD needs to be accounted for in the equity at
// each tick". No MT5, a resolução máxima acessível é por deal fechado.
// Cada deal de trading gera um ponto na série temporal.
//=============================================================================
bool ConstruirSerieEquityPorDeal(SerieTemporal &st,
                                  datetime inicio, datetime fim,
                                  double saldo_ini_param,
                                  double &saldo_base, double &lucro_total,
                                  double &externos_total,
                                  int &deals_ok, int &deals_ig)
{
   ArrayResize(st.tempos,0); ArrayResize(st.saldos,0); st.tamanho=0;
   saldo_base=0; lucro_total=0; externos_total=0; deals_ok=0; deals_ig=0;

   if(fim==0) fim=TimeCurrent();

   // Detecta início automático: primeiro deal de trading nos últimos 10 anos
   if(inicio==0)
   {
      datetime probe = TimeCurrent() - (datetime)(10*365*24*3600);
      if(!HistorySelect(probe,fim)) { Print("HistorySelect(probe) falhou: ",GetLastError()); return false; }
      int tot_p = HistoryDealsTotal();
      datetime mais_ant = (datetime)INT_MAX;
      for(int i=0; i<tot_p; i++)
      {
         ulong tk = HistoryDealGetTicket(i);
         if(!DealEhTrading(tk)) continue;
         datetime dt = (datetime)HistoryDealGetInteger(tk,DEAL_TIME);
         if(dt < mais_ant) mais_ant = dt;
      }
      if(mais_ant==(datetime)INT_MAX) { Print("Nenhum deal de trading encontrado."); return false; }
      inicio = mais_ant;
   }

   if(!HistorySelect(inicio,fim)) { Print("HistorySelect falhou: ",GetLastError()); return false; }
   int tot = HistoryDealsTotal();
   if(tot<=0) { Print("Sem deals no intervalo."); return false; }

   // Pass 1: acumula lucros/externos para estimar saldo inicial
   for(int i=0; i<tot; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      datetime dt = (datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(dt<inicio || dt>fim) continue;
      double luc = HistoryDealGetDouble(tk,DEAL_PROFIT);
      if(DealEhTrading(tk)) lucro_total  += luc;
      else                  externos_total += luc;
   }

   // Estima saldo inicial (mesmo critério do v3.1)
   saldo_base = (saldo_ini_param>0.0) ? saldo_ini_param :
                (AccountInfoDouble(ACCOUNT_BALANCE) - lucro_total - externos_total);
   if(saldo_base <= 0.0) saldo_base = EPSILON;

   // Pass 2: constrói série — ponto inicial + 1 ponto por deal de trading
   double bal = saldo_base;
   ArrayResize(st.tempos,1); ArrayResize(st.saldos,1);
   st.tempos[0]=inicio; st.saldos[0]=bal; st.tamanho=1;

   for(int i=0; i<tot; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      datetime dt = (datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(dt<inicio || dt>fim) continue;
      double luc = HistoryDealGetDouble(tk,DEAL_PROFIT);
      if(DealEhTrading(tk))
      {
         bal += luc;
         ArrayResize(st.tempos, st.tamanho+1);
         ArrayResize(st.saldos, st.tamanho+1);
         st.tempos[st.tamanho] = dt;
         st.saldos[st.tamanho] = bal;
         st.tamanho++;
         deals_ok++;
      }
      else deals_ig++;
   }

   if(st.tamanho < 2) { Print("Série por deal com pontos insuficientes."); return false; }
   return true;
}

//=============================================================================
// SÉRIE TEMPORAL (v3.1 original — mantida como alternativa)
//=============================================================================
bool ConstruirSerieSaldos(SerieTemporal &st,
                          datetime inicio, datetime fim,
                          int passo_segundos, double saldo_ini_param,
                          double &saldo_base, double &lucro_total,
                          double &externos_total, int &deals_ok, int &deals_ig)
{
   ArrayResize(st.tempos,0); ArrayResize(st.saldos,0); st.tamanho=0;
   saldo_base=0; lucro_total=0; externos_total=0; deals_ok=0; deals_ig=0;

   if(passo_segundos<=0) return false;
   if(fim==0) fim=TimeCurrent();

   if(inicio==0)
   {
      datetime probe = TimeCurrent() - (datetime)(10*365*24*3600);
      if(!HistorySelect(probe,fim)) return false;
      int tot_p = HistoryDealsTotal();
      datetime mais_ant=(datetime)INT_MAX;
      for(int i=0; i<tot_p; i++)
      {
         ulong tk=HistoryDealGetTicket(i);
         if(!DealEhTrading(tk)) continue;
         datetime dt=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);
         if(dt<mais_ant) mais_ant=dt;
      }
      if(mais_ant==(datetime)INT_MAX) return false;
      inicio=mais_ant;
   }

   if(!HistorySelect(inicio,fim)) return false;
   int tot=HistoryDealsTotal();
   if(tot<=0) return false;

   int buckets=(int)((fim-inicio)/passo_segundos)+2;
   double soma_bucket[];
   ArrayResize(soma_bucket,buckets);
   ArrayInitialize(soma_bucket,0.0);

   for(int i=0; i<tot; i++)
   {
      ulong tk=HistoryDealGetTicket(i);
      datetime dt=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(dt<inicio||dt>fim) continue;
      double luc=HistoryDealGetDouble(tk,DEAL_PROFIT);
      if(DealEhTrading(tk))
      {
         int idx=(int)((dt-inicio)/passo_segundos);
         if(idx<0) idx=0;
         if(idx>=buckets) idx=buckets-1;
         soma_bucket[idx]+=luc;
         lucro_total+=luc;
         deals_ok++;
      }
      else { externos_total+=luc; deals_ig++; }
   }

   if(deals_ok==0) { Print("Nenhum deal de trading no intervalo."); return false; }

   saldo_base = (saldo_ini_param>0.0) ? saldo_ini_param :
                (AccountInfoDouble(ACCOUNT_BALANCE)-lucro_total-externos_total);
   if(saldo_base<=0.0) saldo_base=EPSILON;

   double bal=saldo_base;
   for(int b=0; b<buckets; b++)
   {
      datetime t_fim=inicio+(datetime)((long)(b+1)*passo_segundos-1);
      if(t_fim>fim) t_fim=fim;
      bal+=soma_bucket[b];
      ArrayResize(st.tempos,st.tamanho+1);
      ArrayResize(st.saldos,st.tamanho+1);
      st.tempos[st.tamanho]=t_fim;
      st.saldos[st.tamanho]=bal;
      st.tamanho++;
      if(t_fim>=fim) break;
   }
   if(st.tamanho<2) return false;
   return true;
}

//=============================================================================
// [FIX 3] SUBTRAÇÃO DO BENCHMARK   (Seção IX do artigo)
//
// PROBLEMA DO v3.1: não existia. O artigo diz que medir o retorno bruto
// confunde o "arrasto" causado pelo índice de mercado com a qualidade da
// estratégia: "it is necessary to subtract the movement of the 'current',
// caused by the stock market index, before evaluating the quality".
//
// SOLUÇÃO: retorno em excesso encadeado.
//   exc[0] = bal[0]  (âncora)
//   exc[i] = exc[i-1] × exp( ln(bal[i]/bal[i-1]) − ln(bench[i]/bench[i-1]) )
// Equivalente (forma fechada mais eficiente):
//   exc[i] = bal[i] × (bench[0] / bench[i])
//
// A série st.saldos[] é substituída pela série em excesso.
// Se benchmark_symbol="" (padrão), a função não é chamada.
//=============================================================================
bool SubtrairBenchmark(SerieTemporal &st, string symbol, ENUM_TIMEFRAMES tf)
{
   if(symbol=="" || st.tamanho<2) return false;

   if(!SymbolSelect(symbol,true))
   {
      PrintFormat("Benchmark '%s': símbolo não encontrado. Subtração ignorada.", symbol);
      return false;
   }

   // Coleta preço de fechamento do benchmark para cada ponto da série
   double bench[];
   ArrayResize(bench, st.tamanho);

   for(int i=0; i<st.tamanho; i++)
   {
      double close_arr[];
      // Tenta a barra que contém st.tempos[i]
      // CopyClose(symbol, tf, from_time, count, buffer[]) — 3º param = datetime → overload temporal
      int copiado = CopyClose(symbol, tf, st.tempos[i], 1, close_arr);
      if(copiado>=1 && close_arr[0]>0.0)
      {
         bench[i] = close_arr[0];
      }
      else
      {
         // Busca retroativamente até 20 barras
         bool found = false;
         for(int back=1; back<=20 && !found; back++)
         {
            datetime t_back = st.tempos[i] - (datetime)((long)back * PeriodSeconds(tf));
            if(CopyClose(symbol,tf,t_back,1,close_arr)>=1 && close_arr[0]>0.0)
            {
               bench[i] = close_arr[0];
               found = true;
            }
         }
         if(!found)
         {
            PrintFormat("Benchmark '%s': sem dado para %s. Subtração cancelada.",
                        symbol, TimeToString(st.tempos[i]));
            return false;
         }
      }
   }

   // Aplica retorno em excesso: exc[i] = bal[i] * bench[0] / bench[i]
   double bench0 = bench[0];
   if(bench0 <= 0.0) { Print("Benchmark: preço inicial inválido."); return false; }

   for(int i=0; i<st.tamanho; i++)
   {
      if(bench[i] > 0.0)
         st.saldos[i] = st.saldos[i] * bench0 / bench[i];
      else
         st.saldos[i] = EPSILON;
   }
   return true;
}

//=============================================================================
// UTILITÁRIOS DE SAÍDA
//=============================================================================
void EscreverArquivo(const string nome, const string texto)
{
   int h = FileOpen(nome, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h != INVALID_HANDLE)
   {
      FileWriteString(h,texto); FileClose(h);
      Print("Resultado gravado em Files\\",nome);
   }
   else Print("Falha ao gravar arquivo: ",nome," err=",GetLastError());
}

void AbrirArquivo(const string caminho)
{
   int r = ShellExecuteW(0,"open",caminho,NULL,NULL,1);
   if(r<=32) PrintFormat("Não foi possível abrir automaticamente. Código: %d",r);
}

//=============================================================================
// OnStart
//=============================================================================
void OnStart()
{
   Print("=== Índice Melão v3.2 iniciado ===");

   // Validações básicas
   if(!usar_equity_por_deal && segundos_periodo<=0)
      { Print("Erro: segundos_periodo deve ser > 0."); return; }
   if(topK < 1)
      { Print("Erro: topK deve ser >= 1."); return; }
   if(inflacao_anual < -0.5 || inflacao_anual > 0.5)
      Print("Aviso: inflação fora do intervalo típico [-50%, +50%].");

   double fator_p = fator_ponderacao;
   if(ponderar_regressao && (fator_p<=0.0 || fator_p>1.0))
      { Print("Aviso: fator_ponderacao inválido, usando 0.95."); fator_p=0.95; }

   if(tempo_inicio!=0 && saldo_inicial_manual<=0.0)
      Print("Aviso: com tempo_inicio explícito e saldo_inicial_manual=0, "
            "o saldo base é aproximado. Informe saldo_inicial_manual para maior precisão.");

   datetime fim    = (tempo_fim   ==0) ? TimeCurrent() : tempo_fim;
   datetime inicio = tempo_inicio;

   // --- Construção da série de equity ---
   SerieTemporal st;
   double saldo_base=0, lucro_total=0, externos_total=0;
   int deals_ok=0, deals_ig=0;
   bool ok;

   if(usar_equity_por_deal)
      ok = ConstruirSerieEquityPorDeal(st,inicio,fim,saldo_inicial_manual,
                                       saldo_base,lucro_total,externos_total,
                                       deals_ok,deals_ig);
   else
      ok = ConstruirSerieSaldos(st,inicio,fim,segundos_periodo,saldo_inicial_manual,
                                saldo_base,lucro_total,externos_total,
                                deals_ok,deals_ig);

   if(!ok) { Print("Falha ao construir série. Abortando."); return; }

   int n = st.tamanho;
   if(n < 2) { Print("Pontos insuficientes na série."); return; }

   // Sanitiza saldos não-positivos
   int corrigidos=0;
   for(int i=0; i<n; i++)
      if(st.saldos[i]<=0.0) { st.saldos[i]=EPSILON; corrigidos++; }

   // --- [FIX 3] Subtração do benchmark ---
   bool bench_ok = false;
   if(benchmark_symbol != "")
   {
      bench_ok = SubtrairBenchmark(st, benchmark_symbol, benchmark_tf);
      if(bench_ok)
         PrintFormat("Benchmark '%s' subtraído. Calculando retorno em excesso.", benchmark_symbol);
      else
         Print("Aviso: subtração do benchmark falhou. MeI calculado sobre retorno bruto.");

      // Re-sanitiza após benchmark (pode gerar valores inválidos)
      for(int i=0; i<n; i++)
         if(st.saldos[i]<=0.0) { st.saldos[i]=EPSILON; corrigidos++; }
   }

   // --- Regressão linear sobre ln(saldo) → R anualizado (Seção III) ---
   double inclinacao=0, intercepto=0;
   if(!RegressaoLinearLnSaldo(st.tempos,st.saldos,n,inclinacao,intercepto,
                              ponderar_regressao,fator_p))
      { Print("Regressão linear falhou."); return; }

   double R = MathExp(inclinacao) - 1.0;
   double T = (double)(st.tempos[n-1]-st.tempos[0]) / SEGUNDOS_POR_ANO;
   if(T <= 0.0) T = 1.0/365.25;

   // --- Volatilidade (sigma) ---
   double logrets[];
   ArrayResize(logrets, n-1);
   for(int i=1; i<n; i++) logrets[i-1]=MathLog(st.saldos[i]/st.saldos[i-1]);
   double sigma_passo = DesvioPadraoAmostral(logrets, n-1);

   // Períodos por ano: por deal → (n-1)/T; temporal → SEGUNDOS_POR_ANO/passo
   double periodos_ano = usar_equity_por_deal ?
                         ((T>0.0) ? (double)(n-1)/T : 1.0) :
                         (SEGUNDOS_POR_ANO/(double)segundos_periodo);
   double sigma_anual  = sigma_passo * MathSqrt(periodos_ano);

   // --- Drawdowns ---
   double dd_frac[];
   int n_dd=0;
   CalcularEpisodiosDrawdown(st.saldos, n, dd_frac, n_dd);

   // MDD bruto medido (para referência no relatório)
   double maior_mdd=0.0;
   for(int i=0; i<n_dd; i++) if(dd_frac[i]>maior_mdd) maior_mdd=dd_frac[i];
   double mdd_star_medido = TransformarParaMDDestrela(maior_mdd);

   // --- [FIX 1+4] MDD* via estimativa Bayesiana ---
   string det_bayes="";
   double MDDestrela = MDDStarBayesiano(dd_frac, n_dd, topK, det_bayes);

   // --- Cálculo do MeI  [equação 4] ---
   double ln_r=0, ln_i=0, ln_d=0;
   bool okR = Ln1pSeguro(R,              ln_r);
   bool okI = Ln1pSeguro(inflacao_anual, ln_i);
   bool okD = Ln1pSeguro(MDDestrela,     ln_d);

   bool   MeI_valido = (okR && okI && okD && T>0.0 && MathAbs(ln_d)>EPSILON);
   double MeI        = MeI_valido ? (ln_r-ln_i)/ln_d * MathSqrt(T) : 0.0;

   // --- Montagem do relatório ---
   string modo_serie = usar_equity_por_deal ?
                       "Por deal (granularidade máxima)" :
                       StringFormat("Temporal (%d s/ponto)",segundos_periodo);
   string bench_str = (benchmark_symbol=="") ? "desativado" :
                      (bench_ok ? benchmark_symbol+" (aplicado)" :
                                  benchmark_symbol+" (FALHOU — retorno bruto usado)");

   string s="";
   s += "RELATÓRIO DO ÍNDICE MELÃO (MeI) v3.2\n";
   s += "======================================\n";
   s += "Início : "+TimeToString(st.tempos[0],  TIME_DATE|TIME_MINUTES)+"\n";
   s += "Fim    : "+TimeToString(st.tempos[n-1],TIME_DATE|TIME_MINUTES)+"\n";
   s += StringFormat("T (anos)             : %.6f\n", T);
   s += StringFormat("Pontos na série      : %d\n",   n);
   s += StringFormat("Modo de série        : %s\n",   modo_serie);
   s += StringFormat("Deals de trading     : %d\n",   deals_ok);
   s += StringFormat("Deals não-trading    : %d\n",   deals_ig);
   s += StringFormat("Saldo base estimado  : %.8f\n", saldo_base);
   s += StringFormat("Benchmark            : %s\n",   bench_str);
   if(corrigidos>0)
      s += StringFormat("Saldos corrigidos    : %d (≤0 → EPSILON)\n", corrigidos);
   s += "\n";

   s += StringFormat("R anualizado (regressão) : %.6f  (%.4f%% a.a.)\n", R, R*100.0);
   s += StringFormat("Inflação anual           : %.6f  (%.4f%% a.a.)\n", inflacao_anual, inflacao_anual*100.0);
   s += StringFormat("Sigma anualizado         : %.6f\n", sigma_anual);
   s += StringFormat("Períodos/ano usados      : %.2f\n", periodos_ano);
   s += "\n";

   s += StringFormat("Episódios de drawdown  : %d\n", n_dd);
   s += StringFormat("MDD medido (maior)     : %.4f%%  →  MDD* = %.8f\n",
                     maior_mdd*100.0, mdd_star_medido);
   s += "\n";

   s += "--- Estimativa Bayesiana do MDD* [FIX 1+4 — Seção VII] ---\n";
   s += det_bayes;
   s += "\n";

   if(MeI_valido)
      s += StringFormat(">>> MeI = %.12f <<<\n", MeI);
   else
   {
      s += ">>> MeI = INVÁLIDO <<<\n";
      if(!okR) s += "    Causa: R inválido (ln(1+R) falhou)\n";
      if(!okI) s += "    Causa: inflação inválida (ln(1+i) falhou)\n";
      if(!okD) s += "    Causa: MDD* inválido ou zero (ln(1+MDD*) falhou)\n";
      if(T<=0) s += "    Causa: T ≤ 0\n";
   }

   s += "\n--- Fórmulas e correções aplicadas ---\n";
   s += "  MDD*     = MDD / (1-MDD)                                  [eq. 3]\n";
   s += "  MeI      = [ln(1+R)-ln(1+i)] / ln(1+MDD*) × √T           [eq. 4]\n";
   s += "  R via regressão linear sobre ln(saldo) vs. tempo           [Seção III]\n";
   s += "  MDD* via estimativa bayesiana (posições percentílicas)     [FIX 1+4 — Seção VII]\n";
   if(usar_equity_por_deal)
      s += "  Série por deal → resolução máxima disponível no MT5        [FIX 2 — Seção VII]\n";
   if(bench_ok)
      s += StringFormat("  Retorno em excesso: bal[i] × bench[0]/bench[i] ('%s') [FIX 3 — Seção IX]\n",
                        benchmark_symbol);
   if(ponderar_regressao)
      s += StringFormat("  Regressão ponderada exponencialmente (fator=%.2f)        [Seção III]\n",
                        fator_p);
   s += "\n  Todas as taxas em decimais (ex: 0.10 = 10%)\n";

   Print(s);

   if(gravarArquivo)
   {
      string nome_arq = "IndiceMelao_v4_resultado.txt";
      EscreverArquivo(nome_arq, s);
      string caminho = TerminalInfoString(TERMINAL_DATA_PATH)+"\\MQL5\\Files\\"+nome_arq;
      Print("Arquivo completo: ",caminho);
      if(abrirArquivoAoFinal) AbrirArquivo(caminho);
   }

   Print("=== Índice Melão v3.2 finalizado ===");
}
//+------------------------------------------------------------------+
