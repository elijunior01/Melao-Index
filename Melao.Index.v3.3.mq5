//+-------------------------------------------------------------------------+
//|                                                    IndiceMelao_v3.3.mq5 |
//|                        Índice Melão (MeI) — Calculadora v3.3            |
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
//|                                                                         |
//| MELHORIAS v3.3:                                                         |
//|                                                                         |
//| [MEL 1]   Aviso de período curto + retorno real do período exibido      |
//|           separadamente do R anualizado extrapolado. Alerta quando      |
//|           T < 0.25 anos (3 meses), pois a anualização se torna          |
//|           estatisticamente instável.                                     |
//|                                                                         |
//| [MEL 2]   MDD* e MeI projetados para horizonte de T=1 ano via √T        |
//|           scaling (Seção VII). Permite comparar estratégias com         |
//|           históricos de durações diferentes em base comum.              |
//|                                                                         |
//| [MEL 3]   Swap e comissão incluídos no saldo por deal. DEAL_SWAP e      |
//|           DEAL_COMMISSION são campos separados no MT5 — ignorá-los      |
//|           distorce o saldo real e consequentemente o MDD capturado.     |
//|                                                                         |
//| [MEL 4]   MeI em 3 janelas móveis de igual número de deals. Revela      |
//|           se a estratégia é estável ou se o MeI global é produto de     |
//|           um único período de sorte (crítica do artigo ao fundo         |
//|           Jureia, Seção VI).                                            |
//|                                                                         |
//| [MEL 5]   Recovery Factor e Profit Factor calculados internamente e     |
//|           exibidos no relatório para referência cruzada com o MeI.      |
//|                                                                         |
//| [MEL 6]   Validação e sugestão automática de topK com base em √n_dd.    |
//|           Evita que o estimador bayesiano opere com amostra insuficiente.|
//|                                                                         |
//| [MEL 7]   Persistência histórica em CSV cumulativo. Cada execução       |
//|           acrescenta uma linha em IndiceMelao_historico.csv, permitindo  |
//|           acompanhar a evolução do MeI ao longo do tempo da conta.      |
//+-------------------------------------------------------------------------+
#property copyright "Eli Batista de Faria Junior"
#property link      "https://www.linkedin.com/in/eli-batista-de-faria-j%C3%BAnior-430a5987/"
#property version   "3.3"
#property strict
#property script_show_inputs

#import "shell32.dll"
int ShellExecuteW(int hWnd,string lpOperation,string lpFile,
                  string lpParameters,string lpDirectory,int nShowCmd);
#import

#define SEGUNDOS_POR_ANO  (365.25*24.0*3600.0)
#define EPSILON           1e-8
#define T_MINIMO_AVISO    0.25   // [MEL 1] alerta se histórico < 3 meses

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
input bool            gravarCSVHistorico   = true; // [MEL 7] acumula execuções em CSV

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
//=============================================================================
double InvNormalCDF(double p)
{
   if(p <= 0.0) return -1e12;
   if(p >= 1.0) return  1e12;

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

// Detecta episódios pico→vale completos.
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
// Usa n_total (pontos da série de equity) no cálculo percentílico,
// conforme o exemplo numérico da Seção VII.
//=============================================================================
double MDDStarBayesiano(const double &dd_frac[], int n_dd, int n_total, int k_max, string &detalhe)
{
   detalhe = "";
   if(n_dd <= 0) { detalhe="Nenhum episódio de drawdown detectado.\n"; return 0.0; }

   double mdd_star[];
   ArrayResize(mdd_star, n_dd);
   for(int i=0; i<n_dd; i++) mdd_star[i] = TransformarParaMDDestrela(dd_frac[i]);
   OrdenarDescendente(mdd_star, n_dd);

   double media=0.0;
   for(int i=0; i<n_dd; i++) media += mdd_star[i];
   media /= n_dd;

   double p1 = (double)n_total / (double)(n_total+1);
   double z1 = InvNormalCDF(p1);

   int usar_k = (k_max < n_dd) ? k_max : n_dd;
   double max_est = mdd_star[0];

   detalhe += StringFormat("n_episodios=%d | n_total(serie)=%d | media(MDD*)=%.6f | z(k=1)=%.4f\n",
                           n_dd, n_total, media, z1);
   detalhe += "k      MDD*_k       p_k     z_k     sigma_k      est_k\n";
   detalhe += "-----  -----------  ------  ------  -----------  -----------\n";

   for(int k=1; k<=usar_k; k++)
   {
      double p_k = (double)(n_total - k + 1) / (double)(n_total + 1);
      double z_k = InvNormalCDF(p_k);

      if(z_k <= EPSILON)
      {
         detalhe += StringFormat("k=%-4d ignorado (z_k=%.4f <= 0)\n", k, z_k);
         continue;
      }

      double sigma_k = (mdd_star[k-1] - media) / z_k;
      if(sigma_k <= 0.0)
      {
         detalhe += StringFormat("k=%-4d ignorado (sigma_k=%.6f <= 0)\n", k, sigma_k);
         continue;
      }

      double est_k   = media + z1 * sigma_k;
      bool novo_max  = (est_k > max_est);
      if(novo_max) max_est = est_k;

      detalhe += StringFormat("%-5d  %-11.6f  %-6.4f  %-6.4f  %-11.6f  %-11.6f%s\n",
                              k, mdd_star[k-1], p_k, z_k, sigma_k, est_k,
                              novo_max ? " <- novo max" : "");
   }
   detalhe += StringFormat("\nMDD* Bayesiano final = %.8f  (MDD equivalente = %.4f%%)\n",
                           max_est, max_est/(1.0+max_est)*100.0);
   return max_est;
}

//=============================================================================
// [MEL 4] MeI EM JANELA   — calcula MeI para um sub-array da série
//=============================================================================
double CalcularMeIJanela(const datetime &tempos[], const double &saldos[],
                         int ini, int fim_idx,
                         double infl, bool pond, double fator_p,
                         int topK_j, string &resumo)
{
   resumo = "";
   int nj = fim_idx - ini;
   if(nj < 2) { resumo = "pontos insuficientes"; return 0.0; }

   datetime sub_t[]; double sub_s[];
   ArrayResize(sub_t, nj); ArrayResize(sub_s, nj);
   for(int i=0; i<nj; i++) { sub_t[i]=tempos[ini+i]; sub_s[i]=saldos[ini+i]; }

   double inc_j=0, icp_j=0;
   if(!RegressaoLinearLnSaldo(sub_t, sub_s, nj, inc_j, icp_j, pond, fator_p))
      { resumo="regressão falhou"; return 0.0; }

   double Rj  = MathExp(inc_j) - 1.0;
   double Tj  = (double)(sub_t[nj-1] - sub_t[0]) / SEGUNDOS_POR_ANO;
   if(Tj <= 0.0) { resumo="T=0"; return 0.0; }

   double dd_j[]; int n_ddj=0;
   CalcularEpisodiosDrawdown(sub_s, nj, dd_j, n_ddj);

   string det_dummy="";
   double mdd_star_j = MDDStarBayesiano(dd_j, n_ddj, nj, topK_j, det_dummy);

   double ln_r=0, ln_i=0, ln_d=0;
   if(!Ln1pSeguro(Rj, ln_r) || !Ln1pSeguro(infl, ln_i) ||
      !Ln1pSeguro(mdd_star_j, ln_d) || MathAbs(ln_d) < EPSILON)
      { resumo="calculo invalido"; return 0.0; }

   double mei_j = (ln_r - ln_i) / ln_d * MathSqrt(Tj);

   // MDD maior na janela
   double mdd_j_max=0.0;
   for(int i=0; i<n_ddj; i++) if(dd_j[i]>mdd_j_max) mdd_j_max=dd_j[i];

   resumo = StringFormat("deals=%d | T=%.4f anos | R=%.2f%% a.a. | MDD=%.2f%% | MeI=%.4f",
                         nj-1, Tj, Rj*100.0, mdd_j_max*100.0, mei_j);
   return mei_j;
}

//=============================================================================
// [FIX 2] + [MEL 3] CONSTRUÇÃO DA SÉRIE POR DEAL
// Inclui swap e comissão no saldo (DEAL_SWAP + DEAL_COMMISSION).
//=============================================================================
bool ConstruirSerieEquityPorDeal(SerieTemporal &st,
                                  datetime inicio, datetime fim,
                                  double saldo_ini_param,
                                  double &saldo_base, double &lucro_total,
                                  double &externos_total,
                                  double &swap_total, double &comis_total,
                                  int &deals_ok, int &deals_ig)
{
   ArrayResize(st.tempos,0); ArrayResize(st.saldos,0); st.tamanho=0;
   saldo_base=0; lucro_total=0; externos_total=0;
   swap_total=0; comis_total=0;
   deals_ok=0; deals_ig=0;

   if(fim==0) fim=TimeCurrent();

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

   // Pass 1: acumula lucros/swap/comissão/externos para estimar saldo inicial
   for(int i=0; i<tot; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      datetime dt = (datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(dt<inicio || dt>fim) continue;
      double luc   = HistoryDealGetDouble(tk, DEAL_PROFIT);
      double swap  = HistoryDealGetDouble(tk, DEAL_SWAP);
      double comis = HistoryDealGetDouble(tk, DEAL_COMMISSION);
      if(DealEhTrading(tk))
      {
         lucro_total  += luc;
         swap_total   += swap;
         comis_total  += comis;
      }
      else externos_total += luc;
   }

   // Estima saldo inicial considerando lucro + swap + comissão
   double liquido_total = lucro_total + swap_total + comis_total;
   saldo_base = (saldo_ini_param>0.0) ? saldo_ini_param :
                (AccountInfoDouble(ACCOUNT_BALANCE) - liquido_total - externos_total);
   if(saldo_base <= 0.0) saldo_base = EPSILON;

   // Pass 2: constrói série com saldo líquido real (lucro + swap + comissão)
   double bal = saldo_base;
   ArrayResize(st.tempos,1); ArrayResize(st.saldos,1);
   st.tempos[0]=inicio; st.saldos[0]=bal; st.tamanho=1;

   for(int i=0; i<tot; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      datetime dt = (datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(dt<inicio || dt>fim) continue;
      if(DealEhTrading(tk))
      {
         double luc   = HistoryDealGetDouble(tk, DEAL_PROFIT);
         double swap  = HistoryDealGetDouble(tk, DEAL_SWAP);
         double comis = HistoryDealGetDouble(tk, DEAL_COMMISSION);
         bal += luc + swap + comis;   // [MEL 3] saldo líquido real
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
// SÉRIE TEMPORAL (alternativa ao modo por deal)
//=============================================================================
bool ConstruirSerieSaldos(SerieTemporal &st,
                          datetime inicio, datetime fim,
                          int passo_segundos, double saldo_ini_param,
                          double &saldo_base, double &lucro_total,
                          double &externos_total,
                          double &swap_total, double &comis_total,
                          int &deals_ok, int &deals_ig)
{
   ArrayResize(st.tempos,0); ArrayResize(st.saldos,0); st.tamanho=0;
   saldo_base=0; lucro_total=0; externos_total=0;
   swap_total=0; comis_total=0;
   deals_ok=0; deals_ig=0;

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
      double luc   = HistoryDealGetDouble(tk, DEAL_PROFIT);
      double swap  = HistoryDealGetDouble(tk, DEAL_SWAP);
      double comis = HistoryDealGetDouble(tk, DEAL_COMMISSION);
      if(DealEhTrading(tk))
      {
         int idx=(int)((dt-inicio)/passo_segundos);
         if(idx<0) idx=0;
         if(idx>=buckets) idx=buckets-1;
         soma_bucket[idx] += luc + swap + comis;  // [MEL 3]
         lucro_total += luc;
         swap_total  += swap;
         comis_total += comis;
         deals_ok++;
      }
      else { externos_total+=luc; deals_ig++; }
   }

   if(deals_ok==0) { Print("Nenhum deal de trading no intervalo."); return false; }

   double liquido_total = lucro_total + swap_total + comis_total;
   saldo_base = (saldo_ini_param>0.0) ? saldo_ini_param :
                (AccountInfoDouble(ACCOUNT_BALANCE) - liquido_total - externos_total);
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
//=============================================================================
bool SubtrairBenchmark(SerieTemporal &st, string symbol, ENUM_TIMEFRAMES tf)
{
   if(symbol=="" || st.tamanho<2) return false;

   if(!SymbolSelect(symbol,true))
   {
      PrintFormat("Benchmark '%s': simbolo nao encontrado. Subtracao ignorada.", symbol);
      return false;
   }

   double bench[];
   ArrayResize(bench, st.tamanho);

   for(int i=0; i<st.tamanho; i++)
   {
      double close_arr[];
      int copiado = CopyClose(symbol, tf, st.tempos[i], 1, close_arr);
      if(copiado>=1 && close_arr[0]>0.0)
      {
         bench[i] = close_arr[0];
      }
      else
      {
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
            PrintFormat("Benchmark '%s': sem dado para %s. Subtracao cancelada.",
                        symbol, TimeToString(st.tempos[i]));
            return false;
         }
      }
   }

   double bench0 = bench[0];
   if(bench0 <= 0.0) { Print("Benchmark: preco inicial invalido."); return false; }

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
   if(r<=32) PrintFormat("Nao foi possivel abrir automaticamente. Codigo: %d",r);
}

//=============================================================================
// [MEL 7] PERSISTÊNCIA HISTÓRICA EM CSV
//=============================================================================
void GravarCSVHistorico(double T, double R, double R_periodo,
                        double maior_mdd, double MDDestrela,
                        double MeI, double MeI_proj,
                        double sigma_anual, double recovery_factor,
                        double profit_factor, int n, int n_dd,
                        bool bench_ok, string bench_sym)
{
   string csv = "IndiceMelao_historico.csv";
   bool novo = (FileIsExist(csv) == false);

   int h = FileOpen(csv, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(h == INVALID_HANDLE)
   {
      Print("Falha ao abrir CSV historico: ", GetLastError());
      return;
   }

   // Escreve cabeçalho apenas se o arquivo for novo
   if(novo)
   {
      FileWrite(h,
                "DataExecucao","T_anos","R_anual_pct","R_periodo_pct",
                "MDD_pct","MDD_star","MeI","MeI_proj_1ano",
                "Sigma_anual","RecoveryFactor","ProfitFactor",
                "Pontos","Episodios_DD","Benchmark");
   }

   FileSeek(h, 0, SEEK_END);
   FileWrite(h,
             TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
             DoubleToString(T,6),
             DoubleToString(R*100.0,4),
             DoubleToString(R_periodo*100.0,4),
             DoubleToString(maior_mdd*100.0,4),
             DoubleToString(MDDestrela,8),
             DoubleToString(MeI,6),
             DoubleToString(MeI_proj,6),
             DoubleToString(sigma_anual,6),
             DoubleToString(recovery_factor,4),
             DoubleToString(profit_factor,4),
             IntegerToString(n),
             IntegerToString(n_dd),
             bench_ok ? bench_sym : "desativado");
   FileClose(h);
   Print("Linha adicionada ao CSV historico: Files\\", csv);
}

//=============================================================================
// OnStart
//=============================================================================
void OnStart()
{
   Print("=== Indice Melao v3.3 iniciado ===");

   // Validações básicas
   if(!usar_equity_por_deal && segundos_periodo<=0)
      { Print("Erro: segundos_periodo deve ser > 0."); return; }
   if(topK < 1)
      { Print("Erro: topK deve ser >= 1."); return; }
   if(inflacao_anual < -0.5 || inflacao_anual > 0.5)
      Print("Aviso: inflacao fora do intervalo tipico [-50%, +50%].");

   double fator_p = fator_ponderacao;
   if(ponderar_regressao && (fator_p<=0.0 || fator_p>1.0))
      { Print("Aviso: fator_ponderacao invalido, usando 0.95."); fator_p=0.95; }

   if(tempo_inicio!=0 && saldo_inicial_manual<=0.0)
      Print("Aviso: com tempo_inicio explicito e saldo_inicial_manual=0, "
            "o saldo base e aproximado. Informe saldo_inicial_manual para maior precisao.");

   datetime fim    = (tempo_fim   ==0) ? TimeCurrent() : tempo_fim;
   datetime inicio = tempo_inicio;

   // --- Construção da série de equity ---
   SerieTemporal st;
   double saldo_base=0, lucro_total=0, externos_total=0;
   double swap_total=0, comis_total=0;
   int deals_ok=0, deals_ig=0;
   bool ok;

   if(usar_equity_por_deal)
      ok = ConstruirSerieEquityPorDeal(st, inicio, fim, saldo_inicial_manual,
                                       saldo_base, lucro_total, externos_total,
                                       swap_total, comis_total,
                                       deals_ok, deals_ig);
   else
      ok = ConstruirSerieSaldos(st, inicio, fim, segundos_periodo, saldo_inicial_manual,
                                saldo_base, lucro_total, externos_total,
                                swap_total, comis_total,
                                deals_ok, deals_ig);

   if(!ok) { Print("Falha ao construir serie. Abortando."); return; }

   int n = st.tamanho;
   if(n < 2) { Print("Pontos insuficientes na serie."); return; }

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
         PrintFormat("Benchmark '%s' subtraido. Calculando retorno em excesso.", benchmark_symbol);
      else
         Print("Aviso: subtracao do benchmark falhou. MeI calculado sobre retorno bruto.");

      for(int i=0; i<n; i++)
         if(st.saldos[i]<=0.0) { st.saldos[i]=EPSILON; corrigidos++; }
   }

   // --- Regressão linear sobre ln(saldo) → R anualizado (Seção III) ---
   double inclinacao=0, intercepto=0;
   if(!RegressaoLinearLnSaldo(st.tempos, st.saldos, n, inclinacao, intercepto,
                              ponderar_regressao, fator_p))
      { Print("Regressao linear falhou."); return; }

   double R = MathExp(inclinacao) - 1.0;
   double T = (double)(st.tempos[n-1]-st.tempos[0]) / SEGUNDOS_POR_ANO;
   if(T <= 0.0) T = 1.0/365.25;

   // [MEL 1] Retorno real do período (não anualizado)
   double R_periodo = MathExp(inclinacao * T) - 1.0;

   // --- Volatilidade (sigma) ---
   double logrets[];
   ArrayResize(logrets, n-1);
   for(int i=1; i<n; i++) logrets[i-1]=MathLog(st.saldos[i]/st.saldos[i-1]);
   double sigma_passo = DesvioPadraoAmostral(logrets, n-1);

   double periodos_ano = usar_equity_por_deal ?
                         ((T>0.0) ? (double)(n-1)/T : 1.0) :
                         (SEGUNDOS_POR_ANO/(double)segundos_periodo);
   double sigma_anual  = sigma_passo * MathSqrt(periodos_ano);

   // --- Drawdowns ---
   double dd_frac[];
   int n_dd=0;
   CalcularEpisodiosDrawdown(st.saldos, n, dd_frac, n_dd);

   double maior_mdd=0.0;
   for(int i=0; i<n_dd; i++) if(dd_frac[i]>maior_mdd) maior_mdd=dd_frac[i];
   double mdd_star_medido = TransformarParaMDDestrela(maior_mdd);

   // [MEL 6] Sugestão automática de topK
   int topK_recomendado = (int)MathMax(5, MathSqrt((double)n_dd));
   string aviso_topK = "";
   if(n_dd > 0 && topK < topK_recomendado)
      aviso_topK = StringFormat(
         "SUGESTAO [MEL 6]: com %d episodios de drawdown, topK=%d seria mais robusto (atual: topK=%d).",
         n_dd, topK_recomendado, topK);

   // --- [FIX 1+4] MDD* via estimativa Bayesiana ---
   string det_bayes="";
   double MDDestrela = MDDStarBayesiano(dd_frac, n_dd, n, topK, det_bayes);

   // --- Cálculo do MeI  [equação 4] ---
   double ln_r=0, ln_i=0, ln_d=0;
   bool okR = Ln1pSeguro(R,              ln_r);
   bool okI = Ln1pSeguro(inflacao_anual, ln_i);
   bool okD = Ln1pSeguro(MDDestrela,     ln_d);

   bool   MeI_valido = (okR && okI && okD && T>0.0 && MathAbs(ln_d)>EPSILON);
   double MeI        = MeI_valido ? (ln_r-ln_i)/ln_d * MathSqrt(T) : 0.0;

   // [MEL 2] MDD* e MeI projetados para T=1 ano via √T scaling
   double MeI_projetado   = 0.0;
   double mdd_star_proj   = 0.0;
   double mdd_proj_frac   = 0.0;
   bool   MeI_proj_valido = false;
   if(MeI_valido && T > 0.0 && T < 1.0)
   {
      double fator_escala = MathSqrt(1.0 / T);
      mdd_star_proj = MDDestrela * fator_escala;
      mdd_proj_frac = mdd_star_proj / (1.0 + mdd_star_proj);
      double ln_d_proj = MathLog(1.0 + mdd_star_proj);
      if(ln_d_proj > EPSILON)
      {
         MeI_projetado   = (ln_r - ln_i) / ln_d_proj; // sem √T pois T→1
         MeI_proj_valido = true;
      }
   }

   // [MEL 5] Recovery Factor e Profit Factor
   double gross_profit=0.0, gross_loss=0.0;
   {
      // Recalcula a partir do histórico já carregado
      int tot_h = HistoryDealsTotal();
      datetime t0 = st.tempos[0];
      datetime t1 = st.tempos[n-1];
      for(int i=0; i<tot_h; i++)
      {
         ulong tk = HistoryDealGetTicket(i);
         if(!DealEhTrading(tk)) continue;
         datetime dt = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
         if(dt < t0 || dt > t1) continue;
         double luc   = HistoryDealGetDouble(tk, DEAL_PROFIT);
         double swap  = HistoryDealGetDouble(tk, DEAL_SWAP);
         double comis = HistoryDealGetDouble(tk, DEAL_COMMISSION);
         double liq   = luc + swap + comis;
         if(liq > 0.0) gross_profit += liq;
         else          gross_loss   += liq;
      }
   }
   double profit_factor   = (MathAbs(gross_loss) > EPSILON) ?
                            gross_profit / MathAbs(gross_loss) : 0.0;
   double recovery_factor = (maior_mdd > EPSILON && saldo_base > EPSILON) ?
                            ((lucro_total + swap_total + comis_total) /
                             (saldo_base * maior_mdd)) : 0.0;

   // [MEL 4] MeI por janelas móveis (3 janelas de igual nº de deals)
   string janela_1="", janela_2="", janela_3="";
   double mei_j1=0, mei_j2=0, mei_j3=0;
   int topK_j = (int)MathMax(3, topK/2);
   if(n >= 6)
   {
      int sz = n / 3;
      mei_j1 = CalcularMeIJanela(st.tempos, st.saldos, 0,    sz,   inflacao_anual, ponderar_regressao, fator_p, topK_j, janela_1);
      mei_j2 = CalcularMeIJanela(st.tempos, st.saldos, sz,   sz*2, inflacao_anual, ponderar_regressao, fator_p, topK_j, janela_2);
      mei_j3 = CalcularMeIJanela(st.tempos, st.saldos, sz*2, n,    inflacao_anual, ponderar_regressao, fator_p, topK_j, janela_3);
   }

   // ===========================================================================
   // MONTAGEM DO RELATÓRIO
   // ===========================================================================
   string modo_serie = usar_equity_por_deal ?
                       "Por deal (granularidade maxima)" :
                       StringFormat("Temporal (%d s/ponto)", segundos_periodo);
   string bench_str = (benchmark_symbol=="") ? "desativado" :
                      (bench_ok ? benchmark_symbol+" (aplicado)" :
                                  benchmark_symbol+" (FALHOU - retorno bruto usado)");

   string s="";
   s += "RELATORIO DO INDICE MELAO (MeI) v3.3\n";
   s += "======================================\n";
   s += "Inicio : "+TimeToString(st.tempos[0],  TIME_DATE|TIME_MINUTES)+"\n";
   s += "Fim    : "+TimeToString(st.tempos[n-1],TIME_DATE|TIME_MINUTES)+"\n";
   s += StringFormat("T (anos)             : %.6f\n", T);
   s += StringFormat("Pontos na serie      : %d\n",   n);
   s += StringFormat("Modo de serie        : %s\n",   modo_serie);
   s += StringFormat("Deals de trading     : %d\n",   deals_ok);
   s += StringFormat("Deals nao-trading    : %d\n",   deals_ig);
   s += StringFormat("Saldo base estimado  : %.8f\n", saldo_base);
   s += StringFormat("Benchmark            : %s\n",   bench_str);
   if(corrigidos>0)
      s += StringFormat("Saldos corrigidos    : %d (<=0 -> EPSILON)\n", corrigidos);

   // [MEL 3] breakdown swap/comissão
   s += "\n--- Composicao do resultado liquido [MEL 3] ---\n";
   s += StringFormat("Lucro bruto (trades) : %.2f\n", lucro_total);
   s += StringFormat("Swap total           : %.2f\n", swap_total);
   s += StringFormat("Comissao total       : %.2f\n", comis_total);
   s += StringFormat("Lucro liquido real   : %.2f\n", lucro_total + swap_total + comis_total);

   s += "\n";

   // [MEL 1] R do período + aviso T curto
   if(T < T_MINIMO_AVISO)
      s += StringFormat("*** AVISO [MEL 1]: T=%.4f anos (< 3 meses). R anualizado e extrapolacao\n"
                        "    estatisticamente instavel. Use R_periodo como referencia primaria. ***\n\n", T);

   s += StringFormat("R do periodo (real)      : %.4f%%\n",    R_periodo * 100.0);
   s += StringFormat("R anualizado (regressao) : %.6f  (%.4f%% a.a.)\n", R, R*100.0);
   s += StringFormat("Inflacao anual           : %.6f  (%.4f%% a.a.)\n", inflacao_anual, inflacao_anual*100.0);
   s += StringFormat("Sigma anualizado         : %.6f\n", sigma_anual);
   s += StringFormat("Periodos/ano usados      : %.2f\n", periodos_ano);

   // [MEL 5]
   s += StringFormat("Gross Profit             : %.2f\n", gross_profit);
   s += StringFormat("Gross Loss               : %.2f\n", gross_loss);
   s += StringFormat("Profit Factor            : %.4f\n", profit_factor);
   s += StringFormat("Recovery Factor          : %.4f\n", recovery_factor);

   s += "\n";
   s += StringFormat("Episodios de drawdown  : %d\n", n_dd);
   s += StringFormat("MDD medido (maior)     : %.4f%%  ->  MDD* = %.8f\n",
                     maior_mdd*100.0, mdd_star_medido);

   if(aviso_topK != "")
      s += "*** "+aviso_topK+" ***\n";

   s += "\n--- Estimativa Bayesiana do MDD* [FIX 1+4 - Secao VII] ---\n";
   s += det_bayes;
   s += "\n";

   if(MeI_valido)
      s += StringFormat(">>> MeI = %.12f <<<\n", MeI);
   else
   {
      s += ">>> MeI = INVALIDO <<<\n";
      if(!okR) s += "    Causa: R invalido (ln(1+R) falhou)\n";
      if(!okI) s += "    Causa: inflacao invalida (ln(1+i) falhou)\n";
      if(!okD) s += "    Causa: MDD* invalido ou zero (ln(1+MDD*) falhou)\n";
      if(T<=0) s += "    Causa: T <= 0\n";
   }

   // [MEL 2] MDD* e MeI projetados
   s += "\n--- Projecao para T=1 ano via raiz(T) scaling [MEL 2 - Secao VII] ---\n";
   if(T >= 1.0)
   {
      s += StringFormat("T >= 1 ano: projecao nao aplicavel (T=%.4f).\n", T);
   }
   else if(MeI_proj_valido)
   {
      s += StringFormat("Fator de escala (1/raiz(T)) : %.4f\n", MathSqrt(1.0/T));
      s += StringFormat("MDD* projetado (T->1 ano)   : %.8f  (MDD equiv. = %.4f%%)\n",
                        mdd_star_proj, mdd_proj_frac*100.0);
      s += StringFormat("MeI projetado  (T->1 ano)   : %.6f\n", MeI_projetado);
      s += "Interpretacao: MeI projetado e comparavel com estrategias de historico anual.\n";
   }
   else
      s += "Projecao invalida (MeI base invalido ou MDD* projetado = 0).\n";

   // [MEL 4] MeI por janelas
   s += "\n--- MeI por janelas (estabilidade da estrategia) [MEL 4 - Secao VI] ---\n";
   if(n >= 6)
   {
      s += StringFormat("Janela 1/3: %s | MeI=%.4f\n", janela_1, mei_j1);
      s += StringFormat("Janela 2/3: %s | MeI=%.4f\n", janela_2, mei_j2);
      s += StringFormat("Janela 3/3: %s | MeI=%.4f\n", janela_3, mei_j3);

      // Diagnóstico de consistência
      double vals[3] = {mei_j1, mei_j2, mei_j3};
      double media_j = (mei_j1 + mei_j2 + mei_j3) / 3.0;
      double dp_j    = DesvioPadraoAmostral(vals, 3);
      double cv_j    = (MathAbs(media_j) > EPSILON) ? (dp_j / MathAbs(media_j)) * 100.0 : 0.0;
      s += StringFormat("Media janelas: %.4f | DP: %.4f | CV: %.1f%%\n",
                        media_j, dp_j, cv_j);
      if(cv_j < 30.0)
         s += "Diagnostico: estrategia CONSISTENTE entre janelas (CV < 30%).\n";
      else if(cv_j < 70.0)
         s += "Diagnostico: estrategia MODERADAMENTE consistente (CV 30-70%). Monitorar.\n";
      else
         s += "*** Diagnostico: ALTA variabilidade entre janelas (CV > 70%). Risco de sorte! ***\n";
   }
   else
      s += "Serie muito curta para dividir em 3 janelas (n < 6 pontos).\n";

   s += "\n--- Formulas e correcoes aplicadas ---\n";
   s += "  MDD*     = MDD / (1-MDD)                                  [eq. 3]\n";
   s += "  MeI      = [ln(1+R)-ln(1+i)] / ln(1+MDD*) x raiz(T)      [eq. 4]\n";
   s += "  R via regressao linear sobre ln(saldo) vs. tempo           [Secao III]\n";
   s += "  MDD* via estimativa bayesiana (posicoes percentilicas)     [FIX 1+4 - Secao VII]\n";
   if(usar_equity_por_deal)
      s += "  Serie por deal -> resolucao maxima disponivel no MT5       [FIX 2 - Secao VII]\n";
   if(bench_ok)
      s += StringFormat("  Retorno em excesso: bal[i] x bench[0]/bench[i] ('%s') [FIX 3 - Secao IX]\n",
                        benchmark_symbol);
   s += "  Swap + comissao incluidos no saldo por deal                 [MEL 3]\n";
   if(ponderar_regressao)
      s += StringFormat("  Regressao ponderada exponencialmente (fator=%.2f)        [Secao III]\n",
                        fator_p);
   s += "\n  Todas as taxas em decimais (ex: 0.10 = 10%)\n";

   Print(s);

   if(gravarArquivo)
   {
      string nome_arq = "IndiceMelao_v3.3_resultado.txt";
      EscreverArquivo(nome_arq, s);
      string caminho = TerminalInfoString(TERMINAL_DATA_PATH)+"\\MQL5\\Files\\"+nome_arq;
      Print("Arquivo completo: ", caminho);
      if(abrirArquivoAoFinal) AbrirArquivo(caminho);
   }

   // [MEL 7] CSV histórico
   if(gravarCSVHistorico)
      GravarCSVHistorico(T, R, R_periodo, maior_mdd, MDDestrela,
                         MeI, MeI_projetado, sigma_anual,
                         recovery_factor, profit_factor,
                         n, n_dd, bench_ok, benchmark_symbol);

   Print("=== Indice Melao v3.3 finalizado ===");
}
//+------------------------------------------------------------------+