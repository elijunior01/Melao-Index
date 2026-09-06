//+------------------------------------------------------------------+
//|                    IndiceMelao_v3.5.mq5                         |
//|              Índice Melão (MeI) — Calculadora v3.5              |
//|                                                                  |
//| Implementação baseada no artigo:                                |
//| "THE MELAO INDEX: A NEW STANDARD FOR RISK-RETURN ANALYSIS..."  |
//| SSRN-id5188185                                                   |
//|                                                                  |
//| PRINCIPAIS CORREÇÕES v3.4                                        |
//|                                                                  |
//| [FIX 1] Saldo histórico reconstruído pela evolução real da     |
//|         conta. Não usa mais ACCOUNT_BALANCE - lucro como        |
//|         aproximação quando o período termina no passado.        |
//|                                                                  |
//| [FIX 2] Descoberta automática do primeiro deal sem a limitação  |
//|         artificial de 10 anos.                                  |
//|                                                                  |
//| [FIX 3] Regressão temporal como padrão profissional, evitando   |
//|         que uma estratégia com mais trades receba peso extra    |
//|         simplesmente por ter maior frequência de operações.    |
//|         O modo por deal continua disponível para auditoria.     |
//|                                                                  |
//| [FIX 4] MDD Bayesiano: a posição percentílica é calculada sobre |
//|         os próprios episódios de drawdown (n_dd), e não sobre   |
//|         o número de pontos da série. Isso reproduz a lógica do   |
//|         exemplo da Seção VII (ex.: 68 episódios -> 68/69).      |
//|                                                                  |
//| [FIX 5] Benchmark sem look-ahead: usa somente o último candle   |
//|         FECHADO disponível até cada instante da série.           |
//|                                                                  |
//| [FIX 6] Benchmark e Recovery Factor ficam em bases consistentes.|
//|                                                                  |
//| [FIX 7] Janelas de estabilidade passam a ser temporais quando   |
//|         a série principal é temporal.                             |
//|                                                                  |
//| [FIX 8] topK continua sendo configurável. A sugestão automática  |
//|         é apenas heurística e é explicitamente marcada como tal. |
//|                                                                  |
//| IMPORTANTE                                                        |
//| O MDD v3.5 preserva o MDD v3.4 e adiciona motor híbrido M1        |
//| reconstruída nos pontos disponíveis. Ele NÃO é um MDD tick-a-tick  |
//| completo da equity flutuante intratrade. O próprio artigo ressalta |
//| que o verdadeiro MDD deveria considerar equity a cada tick.       |
//| Uma reconstrução tick-a-tick de uma conta multiativo exige replay   |
//| histórico de ticks de todos os símbolos e posições.               |
//
// v3.5 — MOTOR HÍBRIDO DE RISCO
// Para contas de um único símbolo, o modo híbrido reconstrói a equity
// intraminuto usando os deals reais + candles M1 e testa dois caminhos
// intrabar compatíveis com o OHLC: O-H-L-C e O-L-H-C.
// Isso melhora o MDD realizado/intrabar sem fingir que os ticks históricos
// existem. Para contas multiativo, o motor híbrido não inventa um replay
// incompleto: mantém o MDD v3.4 como fallback.
//
// IMPORTANTE: os caminhos intrabar são sintéticos. Eles são uma extensão
// operacional para períodos sem ticks e ficam separados dos dados reais.
// O MeI principal continua usando a fórmula da v3.4; apenas a fonte de
// risco pode ser substituída pelo estimador híbrido quando elegível.
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
#property copyright "Eli Batista de Faria Junior"
#property link      "https://github.com/elijunior01/Melao-Index"
#property version   "3.5"
#property strict
#property script_show_inputs

#import "shell32.dll"
int ShellExecuteW(int hWnd,string lpOperation,string lpFile,
                  string lpParameters,string lpDirectory,int nShowCmd);
#import

#define SEGUNDOS_POR_ANO   (365.25*24.0*3600.0)
#define EPSILON            1e-10
#define T_MINIMO_AVISO     0.25
#define MAX_BENCH_BACK_BARS 1000

enum ENUM_MODO_SERIE_MELAO
{
   MODO_TEMPORAL = 0,   // Recomendado para comparações de estratégias
   MODO_POR_DEAL = 1,   // Auditoria de máxima granularidade dos deals fechados
   MODO_HIBRIDO   = 2    // Retorno temporal v3.4 + MDD híbrido M1 intrabar
};

//====================================================================
// INPUTS
//====================================================================
input group           "=== Período e Série ==="
input ENUM_MODO_SERIE_MELAO modo_serie        = MODO_TEMPORAL;
input int             segundos_periodo        = 86400; // 1 dia
input datetime        tempo_inicio            = 0;     // 0 = primeiro deal de trading disponível
input datetime        tempo_fim               = 0;     // 0 = agora

input group           "=== Benchmark — opcional ==="
input string          benchmark_symbol        = "";   // Ex.: WIN$N, SPX500
input ENUM_TIMEFRAMES benchmark_tf            = PERIOD_D1;

input group           "=== Motor Híbrido v3.5 ==="
input bool            usar_hibrido_m1          = true;   // Ativa MDD híbrido quando elegível
input int             max_barras_m1_hibrido    = 0;      // 0 = sem limite; >0 limita por segurança
input bool            incluir_caminho_ohlc_1   = true;   // O-H-L-C
input bool            incluir_caminho_ohlc_2   = true;   // O-L-H-C

input group           "=== Parâmetros do MeI ==="
input int             topK                    = 5;
input double          inflacao_anual          = 0.00; // Ex.: 0.04 = 4% a.a.
input double          saldo_inicial_manual    = 0.0;  // 0 = reconstrução automática
input bool            ponderar_regressao      = false;
input double          fator_ponderacao        = 0.95;

input group           "=== Diagnósticos adicionais ==="
input bool            calcular_sigma          = true;
input bool            calcular_janelas       = true;
input int             numero_janelas          = 3;

input group           "=== Saída ==="
input bool            gravarArquivo           = true;
input bool            abrirArquivoAoFinal     = true;
input bool            gravarCSVHistorico      = true;

//====================================================================
// STRUCTS
//====================================================================
struct SerieTemporal
{
   datetime tempos[];
   double   saldos[];
   int      tamanho;
};

struct TotaisConta
{
   double resultado_trading;
   double swap;
   double comissao;
   double fee;
   double externos;
   double resultado_liquido_trading;
   int    deals_trading;
   int    deals_nao_trading;
};

struct JanelaInfo
{
   datetime inicio;
   datetime fim;
   double mei;
   double R;
   double T;
   double mdd;
   int pontos;
   string status;
};

struct ResultadoHibrido
{
   bool   valido;
   bool   multiativo;
   string simbolo;
   string caminho;
   double mdd;
   double mdd_star_medido;
   double mdd_star_bayes;
   int    n_dd;
   double cobertura_m1;
   string status;
};

//====================================================================
// INVERSA DA NORMAL PADRÃO — Peter Acklam
//====================================================================
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

   const double p_low  = 0.02425;
   const double p_high = 1.0 - p_low;

   double q,r,x;
   if(p < p_low)
   {
      q = MathSqrt(-2.0*MathLog(p));
      x = (((((c1*q+c2)*q+c3)*q+c4)*q+c5)*q+c6) /
          ((((d1*q+d2)*q+d3)*q+d4)*q+1.0);
   }
   else if(p <= p_high)
   {
      q = p-0.5;
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

//====================================================================
// MATEMÁTICA AUXILIAR
//====================================================================
bool Ln1pSeguro(double x,double &saida)
{
   if(x <= -1.0) return false;
   saida=MathLog(1.0+x);
   return true;
}

double DesvioPadraoAmostral(const double &arr[],int n)
{
   if(n<=1) return 0.0;
   double soma=0.0;
   for(int i=0;i<n;i++) soma+=arr[i];
   double media=soma/(double)n;
   double acc=0.0;
   for(int i=0;i<n;i++)
      acc+=(arr[i]-media)*(arr[i]-media);
   return MathSqrt(acc/(double)(n-1));
}

void OrdenarDescendente(double &arr[],int n)
{
   for(int i=0;i<n-1;i++)
      for(int j=0;j<n-1-i;j++)
         if(arr[j]<arr[j+1])
         {
            double t=arr[j]; arr[j]=arr[j+1]; arr[j+1]=t;
         }
}

double TransformarParaMDDestrela(double mdd)
{
   if(mdd<=0.0) return 0.0;
   if(mdd>=0.999999999) return 1e12;
   return mdd/(1.0-mdd);
}

double ConverterMDDStarParaMDD(double mdd_star)
{
   if(mdd_star<=0.0) return 0.0;
   return mdd_star/(1.0+mdd_star);
}

bool DealEhTrading(ulong ticket)
{
   ENUM_DEAL_TYPE t=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
   return (t==DEAL_TYPE_BUY || t==DEAL_TYPE_SELL);
}

// Efeito financeiro do deal no saldo da conta.
// Para trades: profit + swap + commission + fee.
// Para balance/credit e afins: profit + swap + commission + fee.
double EfeitoFinanceiroDeal(ulong ticket)
{
   double profit     = HistoryDealGetDouble(ticket,DEAL_PROFIT);
   double swap       = HistoryDealGetDouble(ticket,DEAL_SWAP);
   double commission = HistoryDealGetDouble(ticket,DEAL_COMMISSION);
   double fee        = HistoryDealGetDouble(ticket,DEAL_FEE);
   return profit+swap+commission+fee;
}

//====================================================================
// REGRESSÃO LN(SALDO) x TEMPO
//====================================================================
bool RegressaoLinearLnSaldo(const datetime &tempos[],
                            const double &saldos[],
                            int n,
                            double &inclinacao_ano,
                            double &intercepto,
                            bool ponderado,
                            double peso_base)
{
   if(n<2) return false;
   if(peso_base<=0.0 || peso_base>1.0) peso_base=0.95;

   double t0=(double)tempos[0];
   double soma_p=0.0;

   double xs[],ys[],pesos[];
   ArrayResize(xs,n);
   ArrayResize(ys,n);
   ArrayResize(pesos,n);

   for(int i=0;i<n;i++)
   {
      if(saldos[i]<=0.0) return false;
      xs[i]=((double)tempos[i]-t0)/SEGUNDOS_POR_ANO;
      ys[i]=MathLog(saldos[i]);
      pesos[i]=ponderado ? MathPow(peso_base,(double)(n-1-i)) : 1.0;
      soma_p+=pesos[i];
   }

   if(soma_p<=0.0) return false;
   for(int i=0;i<n;i++) pesos[i]/=soma_p;

   double mx=0.0,my=0.0;
   for(int i=0;i<n;i++)
   {
      mx+=pesos[i]*xs[i];
      my+=pesos[i]*ys[i];
   }

   double num=0.0,den=0.0;
   for(int i=0;i<n;i++)
   {
      double dx=xs[i]-mx;
      num+=pesos[i]*dx*(ys[i]-my);
      den+=pesos[i]*dx*dx;
   }

   if(MathAbs(den)<EPSILON)
   {
      inclinacao_ano=0.0;
      intercepto=my;
      return true;
   }

   inclinacao_ano=num/den;
   intercepto=my-inclinacao_ano*mx;
   return true;
}

//====================================================================
// DRAW DOWNS — episódios pico -> vale completos
// O último episódio também é considerado, mesmo que ainda não tenha
// retornado ao high-water mark.
//====================================================================
void CalcularEpisodiosDrawdown(const double &saldos[],int n,double &dd[],int &qtd)
{
   qtd=0;
   ArrayResize(dd,0);
   if(n<2) return;

   double pico=saldos[0];
   double vale=saldos[0];
   bool em_dd=false;

   for(int i=1;i<n;i++)
   {
      if(saldos[i]>=pico)
      {
         if(em_dd && pico>EPSILON)
         {
            double mag=(pico-vale)/pico;
            if(mag>EPSILON)
            {
               ArrayResize(dd,qtd+1);
               dd[qtd++]=mag;
            }
         }
         pico=saldos[i];
         vale=saldos[i];
         em_dd=false;
      }
      else
      {
         em_dd=true;
         if(saldos[i]<vale) vale=saldos[i];
      }
   }

   if(em_dd && pico>EPSILON)
   {
      double mag=(pico-vale)/pico;
      if(mag>EPSILON)
      {
         ArrayResize(dd,qtd+1);
         dd[qtd++]=mag;
      }
   }
}

//====================================================================
// MDD* BAYESIANO — interpretação operacional da Seção VII
//
// Correção v3.4:
// o ranking percentílico utiliza N = número de episódios de MDD,
// porque os elementos da amostra usada no ranking são os próprios
// episódios de drawdown.
//====================================================================
double MDDStarBayesiano(const double &dd_frac[],
                        int n_dd,
                        int k_max,
                        string &detalhe,
                        bool &bayes_ok)
{
   detalhe="";
   bayes_ok=false;

   if(n_dd<=0)
   {
      detalhe="Nenhum episódio de drawdown detectado.\n";
      return 0.0;
   }

   double mdd_star[];
   ArrayResize(mdd_star,n_dd);
   for(int i=0;i<n_dd;i++)
      mdd_star[i]=TransformarParaMDDestrela(dd_frac[i]);

   OrdenarDescendente(mdd_star,n_dd);

   if(n_dd<2)
   {
      detalhe="Amostra insuficiente para estimativa Bayesiana; usando MDD* medido.\n";
      detalhe+=StringFormat("n_episodios=%d | MDD*=%.10f\n",n_dd,mdd_star[0]);
      return mdd_star[0];
   }

   double media=0.0;
   for(int i=0;i<n_dd;i++) media+=mdd_star[i];
   media/=(double)n_dd;

   // Exatamente a estrutura do exemplo do artigo:
   // maior MDD em N observações -> N/(N+1)
   double p1=(double)n_dd/(double)(n_dd+1);
   double z1=InvNormalCDF(p1);

   int usar_k=MathMin(k_max,n_dd);
   if(usar_k<1) usar_k=1;

   double max_est=mdd_star[0];

   detalhe+=StringFormat("n_episodios=%d | media(MDD*)=%.10f | z(k=1)=%.6f\n",
                         n_dd,media,z1);
   detalhe+="k      MDD*_k          p_k       z_k        sigma_k        est_k\n";
   detalhe+="-----  --------------  --------  --------  -------------  -------------\n";

   for(int k=1;k<=usar_k;k++)
   {
      double p_k=(double)(n_dd-k+1)/(double)(n_dd+1);
      double z_k=InvNormalCDF(p_k);

      if(z_k<=EPSILON)
      {
         detalhe+=StringFormat("%-5d  ignorado: z_k=%.8f\n",k,z_k);
         continue;
      }

      double sigma_k=(mdd_star[k-1]-media)/z_k;
      if(sigma_k<=0.0)
      {
         detalhe+=StringFormat("%-5d  ignorado: sigma_k=%.10f <= 0\n",k,sigma_k);
         continue;
      }

      double est_k=media+z1*sigma_k;
      bool novo_max=(est_k>max_est);
      if(novo_max) max_est=est_k;

      detalhe+=StringFormat("%-5d  %-14.10f  %-8.5f  %-8.5f  %-13.10f  %-13.10f%s\n",
                            k,mdd_star[k-1],p_k,z_k,sigma_k,est_k,
                            novo_max?"  <- novo max":"");
   }

   // O artigo admite escolher o maior entre as estimativas.
   bayes_ok=true;
   detalhe+=StringFormat("\nMDD* Bayesiano final = %.10f  (MDD equivalente = %.6f%%)\n",
                         max_est,ConverterMDDStarParaMDD(max_est)*100.0);
   return max_est;
}

//====================================================================
// HISTÓRICO: encontrar primeiro deal de trading disponível
//====================================================================
bool EncontrarPrimeiroDealTrading(datetime fim,datetime &primeiro)
{
   primeiro=0;
   if(fim<=0) fim=TimeCurrent();

   ResetLastError();
   if(!HistorySelect(0,fim))
   {
      PrintFormat("HistorySelect(0,%s) falhou. erro=%d",
                  TimeToString(fim),GetLastError());
      return false;
   }

   int total=HistoryDealsTotal();
   datetime mais_ant=0;
   for(int i=0;i<total;i++)
   {
      ulong tk=HistoryDealGetTicket(i);
      if(tk==0) continue;
      if(!DealEhTrading(tk)) continue;

      datetime dt=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(dt<=0) continue;
      if(mais_ant==0 || dt<mais_ant) mais_ant=dt;
   }

   if(mais_ant==0) return false;
   primeiro=mais_ant;
   return true;
}

//====================================================================
// RECONSTRUÇÃO DO SALDO EM UMA DATA
//
// saldo(t) = saldo_atual - soma dos efeitos de todos os deals depois t.
// Isso evita o erro da v3.3 que usava apenas "lucro do período" e depois
// subtraía do ACCOUNT_BALANCE atual, contaminando períodos históricos.
//====================================================================
bool ReconstruirSaldoNaData(datetime t,double &saldo_t)
{
   saldo_t=0.0;
   datetime agora=TimeCurrent();
   if(t>agora) return false;

   ResetLastError();
   if(!HistorySelect(0,agora))
   {
      PrintFormat("HistorySelect(0,agora) falhou em ReconstruirSaldoNaData. erro=%d",GetLastError());
      return false;
   }

   double soma_depois=0.0;
   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong tk=HistoryDealGetTicket(i);
      if(tk==0) continue;
      datetime dt=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(dt>t)
         soma_depois+=EfeitoFinanceiroDeal(tk);
   }

   saldo_t=AccountInfoDouble(ACCOUNT_BALANCE)-soma_depois;
   return (saldo_t>EPSILON);
}

//====================================================================
// TOTAIS DO PERÍODO
//====================================================================
bool CalcularTotaisPeriodo(datetime inicio,datetime fim,TotaisConta &tot)
{
   ZeroMemory(tot);

   if(!HistorySelect(0,fim))
      return false;

   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong tk=HistoryDealGetTicket(i);
      if(tk==0) continue;

      datetime dt=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(dt<inicio || dt>fim) continue;

      double profit=HistoryDealGetDouble(tk,DEAL_PROFIT);
      double swap=HistoryDealGetDouble(tk,DEAL_SWAP);
      double commission=HistoryDealGetDouble(tk,DEAL_COMMISSION);
      double fee=HistoryDealGetDouble(tk,DEAL_FEE);
      double liquido=profit+swap+commission+fee;

      if(DealEhTrading(tk))
      {
         tot.resultado_trading+=profit;
         tot.swap+=swap;
         tot.comissao+=commission;
         tot.fee+=fee;
         tot.resultado_liquido_trading+=liquido;
         tot.deals_trading++;
      }
      else
      {
         tot.externos+=liquido;
         tot.deals_nao_trading++;
      }
   }
   return true;
}

//====================================================================
// CONSTRUÇÃO DE SÉRIE POR DEAL
//
// Retorno por deal é mantido como modo de auditoria, mas o relatório
// sinaliza que essa opção pode dar pesos desiguais à estratégia se usada
// para regressão quando comparada a outra estratégia com frequência
// muito diferente.
//====================================================================
bool ConstruirSeriePorDeal(SerieTemporal &st,
                           datetime inicio,datetime fim,
                           double saldo_manual,
                           double &saldo_base,
                           int &deals_ok,int &deals_ig)
{
   ArrayResize(st.tempos,0);
   ArrayResize(st.saldos,0);
   st.tamanho=0;
   deals_ok=0;
   deals_ig=0;

   if(inicio==0)
   {
      if(!EncontrarPrimeiroDealTrading(fim,inicio))
      {
         Print("Não foi possível encontrar o primeiro deal de trading.");
         return false;
      }
   }

   if(inicio>=fim) return false;

   if(saldo_manual>0.0)
      saldo_base=saldo_manual;
   else if(!ReconstruirSaldoNaData(inicio,saldo_base))
   {
      Print("Falha ao reconstruir saldo inicial.");
      return false;
   }

   if(!HistorySelect(inicio,fim)) return false;

   double bal=saldo_base;
   ArrayResize(st.tempos,1);
   ArrayResize(st.saldos,1);
   st.tempos[0]=inicio;
   st.saldos[0]=bal;
   st.tamanho=1;

   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong tk=HistoryDealGetTicket(i);
      if(tk==0) continue;

      datetime dt=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(dt<inicio || dt>fim) continue;

      if(DealEhTrading(tk))
      {
         bal+=EfeitoFinanceiroDeal(tk);
         if(bal<=EPSILON) bal=EPSILON;

         ArrayResize(st.tempos,st.tamanho+1);
         ArrayResize(st.saldos,st.tamanho+1);
         st.tempos[st.tamanho]=dt;
         st.saldos[st.tamanho]=bal;
         st.tamanho++;
         deals_ok++;
      }
      else
         deals_ig++;
   }

   return (st.tamanho>=2);
}

//====================================================================
// CONSTRUÇÃO DE SÉRIE TEMPORAL
//
// Os pontos são construídos em intervalos fixos. O saldo de cada ponto
// é reconstruído acumulando os efeitos financeiros dos deals ocorridos
// no intervalo. O saldo-base vem da data inicial real, não de uma
// aproximação baseada apenas no lucro do período.
//====================================================================
bool ConstruirSerieTemporal(SerieTemporal &st,
                            datetime inicio,datetime fim,
                            int passo_segundos,
                            double saldo_manual,
                            double &saldo_base,
                            int &deals_ok,int &deals_ig)
{
   ArrayResize(st.tempos,0);
   ArrayResize(st.saldos,0);
   st.tamanho=0;
   deals_ok=0;
   deals_ig=0;

   if(passo_segundos<=0) return false;

   if(inicio==0)
   {
      if(!EncontrarPrimeiroDealTrading(fim,inicio))
      {
         Print("Não foi possível encontrar o primeiro deal de trading.");
         return false;
      }
   }

   if(inicio>=fim) return false;

   if(saldo_manual>0.0)
      saldo_base=saldo_manual;
   else if(!ReconstruirSaldoNaData(inicio,saldo_base))
   {
      Print("Falha ao reconstruir saldo inicial.");
      return false;
   }

   // Histórico completo até fim. Isso evita perder eventos de balance/credit
   // para a reconstrução do saldo e para a classificação dos deals.
   if(!HistorySelect(0,fim)) return false;

   int total=HistoryDealsTotal();
   int buckets=(int)((fim-inicio)/(long)passo_segundos)+2;
   if(buckets<2) buckets=2;

   double soma_bucket[];
   ArrayResize(soma_bucket,buckets);
   ArrayInitialize(soma_bucket,0.0);

   for(int i=0;i<total;i++)
   {
      ulong tk=HistoryDealGetTicket(i);
      if(tk==0) continue;

      datetime dt=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(dt<inicio || dt>fim) continue;

      if(DealEhTrading(tk)) deals_ok++;
      else deals_ig++;

      int idx=(int)((dt-inicio)/(long)passo_segundos);
      if(idx<0) idx=0;
      if(idx>=buckets) idx=buckets-1;

      // Aqui entram tanto trades como eventos de saldo externos, porque a
      // série representa a evolução real da conta. Os eventos externos são
      // contabilizados separadamente no relatório.
      soma_bucket[idx]+=EfeitoFinanceiroDeal(tk);
   }

   if(deals_ok<=0)
   {
      Print("Nenhum deal de trading no período.");
      return false;
   }

   double bal=saldo_base;
   for(int b=0;b<buckets;b++)
   {
      datetime t=inicio+(datetime)((long)(b+1)*(long)passo_segundos-1);
      if(t>fim) t=fim;

      bal+=soma_bucket[b];
      if(bal<=EPSILON) bal=EPSILON;

      ArrayResize(st.tempos,st.tamanho+1);
      ArrayResize(st.saldos,st.tamanho+1);
      st.tempos[st.tamanho]=t;
      st.saldos[st.tamanho]=bal;
      st.tamanho++;

      if(t>=fim) break;
   }

   return (st.tamanho>=2);
}

//====================================================================
// BENCHMARK SEM LOOK-AHEAD
//
// Para cada instante t da série, procura o último candle FECHADO do
// benchmark cuja informação já estava disponível em t.
//====================================================================
bool ObterUltimoFechamentoDisponivel(string symbol,
                                     ENUM_TIMEFRAMES tf,
                                     datetime t,
                                     double &valor)
{
   valor=0.0;
   if(symbol=="") return false;
   if(!SymbolSelect(symbol,true)) return false;

   int shift=iBarShift(symbol,tf,t,false);
   if(shift<0) return false;

   // Candle contendo t pode ainda estar aberto. Para impedir look-ahead,
   // usamos sempre o candle anterior fechado.
   int shift_fechado=shift+1;
   if(shift_fechado<0) shift_fechado=0;

   double c=iClose(symbol,tf,shift_fechado);
   if(c>0.0)
   {
      valor=c;
      return true;
   }

   // Fallback para barras anteriores.
   for(int k=2;k<=MAX_BENCH_BACK_BARS;k++)
   {
      c=iClose(symbol,tf,shift+k-1);
      if(c>0.0)
      {
         valor=c;
         return true;
      }
   }
   return false;
}

bool SubtrairBenchmark(SerieTemporal &st,string symbol,ENUM_TIMEFRAMES tf)
{
   if(symbol=="" || st.tamanho<2) return false;
   if(!SymbolSelect(symbol,true)) return false;

   double bench[];
   ArrayResize(bench,st.tamanho);

   for(int i=0;i<st.tamanho;i++)
   {
      if(!ObterUltimoFechamentoDisponivel(symbol,tf,st.tempos[i],bench[i]))
      {
         PrintFormat("Benchmark '%s': sem fechamento disponível antes de %s.",
                     symbol,TimeToString(st.tempos[i]));
         return false;
      }
   }

   if(bench[0]<=0.0) return false;
   double bench0=bench[0];

   for(int i=0;i<st.tamanho;i++)
   {
      if(bench[i]<=0.0) return false;
      st.saldos[i]*=bench0/bench[i];
      if(st.saldos[i]<=EPSILON) st.saldos[i]=EPSILON;
   }
   return true;
}

//====================================================================
// ESTATÍSTICAS DA SÉRIE
//====================================================================
bool CalcularRetornoRegressao(const SerieTemporal &st,
                              bool ponderado,double fator,
                              double &R,double &R_periodo,double &T)
{
   R=0.0;
   R_periodo=0.0;
   T=0.0;

   if(st.tamanho<2) return false;

   double inc=0.0,inter=0.0;
   if(!RegressaoLinearLnSaldo(st.tempos,st.saldos,st.tamanho,
                              inc,inter,ponderado,fator))
      return false;

   T=(double)(st.tempos[st.tamanho-1]-st.tempos[0])/SEGUNDOS_POR_ANO;
   if(T<=0.0) return false;

   R=MathExp(inc)-1.0;
   R_periodo=MathExp(inc*T)-1.0;
   return true;
}

double CalcularSigmaAnualizado(const SerieTemporal &st,double &passos_ano)
{
   passos_ano=0.0;
   if(st.tamanho<3) return 0.0;

   int n=st.tamanho-1;
   double rets[];
   ArrayResize(rets,n);

   for(int i=1;i<st.tamanho;i++)
   {
      if(st.saldos[i-1]<=0.0 || st.saldos[i]<=0.0) return 0.0;
      rets[i-1]=MathLog(st.saldos[i]/st.saldos[i-1]);
   }

   double T=(double)(st.tempos[st.tamanho-1]-st.tempos[0])/SEGUNDOS_POR_ANO;
   if(T>0.0) passos_ano=(double)n/T;
   else passos_ano=0.0;

   if(passos_ano<=0.0) return 0.0;
   return DesvioPadraoAmostral(rets,n)*MathSqrt(passos_ano);
}

//====================================================================
// MEI PARA UMA JANELA
//====================================================================
bool CalcularMeIJanela(const SerieTemporal &st,
                       int ini,int fim_exclusivo,
                       double infl,
                       bool ponderado,double fator,
                       int topK_j,
                       double &mei,
                       JanelaInfo &info)
{
   mei=0.0;
   ZeroMemory(info);
   info.status="";

   int n=fim_exclusivo-ini;
   if(n<3)
   {
      info.status="pontos insuficientes";
      return false;
   }

   SerieTemporal sub;
   sub.tamanho=n;
   ArrayResize(sub.tempos,n);
   ArrayResize(sub.saldos,n);
   for(int i=0;i<n;i++)
   {
      sub.tempos[i]=st.tempos[ini+i];
      sub.saldos[i]=st.saldos[ini+i];
   }

   double R=0.0,Rp=0.0,T=0.0;
   if(!CalcularRetornoRegressao(sub,ponderado,fator,R,Rp,T))
   {
      info.status="regressão falhou";
      return false;
   }

   double dd[]; int ndd=0;
   CalcularEpisodiosDrawdown(sub.saldos,n,dd,ndd);
   if(ndd<=0)
   {
      info.status="sem drawdown";
      return false;
   }

   string det="";
   bool bayes=false;
   double mddstar=MDDStarBayesiano(dd,ndd,topK_j,det,bayes);
   if(mddstar<=0.0)
   {
      info.status="MDD* inválido";
      return false;
   }

   double lnr,lni,lnd;
   if(!Ln1pSeguro(R,lnr) || !Ln1pSeguro(infl,lni) || !Ln1pSeguro(mddstar,lnd))
   {
      info.status="ln inválido";
      return false;
   }

   if(MathAbs(lnd)<EPSILON)
   {
      info.status="MDD* praticamente zero";
      return false;
   }

   mei=(lnr-lni)/lnd*MathSqrt(T);

   double maior=0.0;
   for(int i=0;i<ndd;i++)
      if(dd[i]>maior) maior=dd[i];

   info.inicio=sub.tempos[0];
   info.fim=sub.tempos[n-1];
   info.mei=mei;
   info.R=R;
   info.T=T;
   info.mdd=maior;
   info.pontos=n;
   info.status=bayes?"ok":"MDD* medido (sem Bayes suficiente)";
   return true;
}

//====================================================================
// JANELAS TEMPORAIS / POR PONTOS
//====================================================================
int EncontrarIndicePorTempo(const SerieTemporal &st,datetime t)
{
   for(int i=0;i<st.tamanho;i++)
      if(st.tempos[i]>=t) return i;
   return st.tamanho-1;
}

//====================================================================
// SAÍDA
//====================================================================
void EscreverArquivo(const string nome,const string texto)
{
   int h=FileOpen(nome,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
   {
      PrintFormat("Falha ao gravar '%s'. erro=%d",nome,GetLastError());
      return;
   }
   FileWriteString(h,texto);
   FileClose(h);
   Print("Resultado gravado em MQL5\\Files\\",nome);
}

void AbrirArquivo(const string caminho)
{
   int r=ShellExecuteW(0,"open",caminho,NULL,NULL,1);
   if(r<=32)
      PrintFormat("Não foi possível abrir automaticamente. código=%d",r);
}

void GravarCSVHistorico(const string nome_csv,
                        double T,double R,double Rperiodo,
                        double MDD,double MDDstar,double MeI,
                        double MeIproj,
                        double sigma,double recovery,double PF,
                        int pontos,int ndd,
                        bool benchmark_ok,string benchmark,
                        string modo)
{
   bool novo=!FileIsExist(nome_csv);
   int h=FileOpen(nome_csv,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(h==INVALID_HANDLE)
   {
      PrintFormat("Falha ao abrir CSV histórico. erro=%d",GetLastError());
      return;
   }

   if(novo)
   {
      FileWrite(h,
                "DataExecucao","Modo","T_anos","R_anual_pct","R_periodo_pct",
                "MDD_pct","MDD_star","MeI","MeI_proj_1ano",
                "Sigma_anual","RecoveryFactor","ProfitFactor",
                "Pontos","Episodios_DD","Benchmark");
   }

   FileSeek(h,0,SEEK_END);
   FileWrite(h,
             TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES),
             modo,
             DoubleToString(T,8),
             DoubleToString(R*100.0,6),
             DoubleToString(Rperiodo*100.0,6),
             DoubleToString(MDD*100.0,6),
             DoubleToString(MDDstar,10),
             DoubleToString(MeI,10),
             DoubleToString(MeIproj,10),
             DoubleToString(sigma,8),
             DoubleToString(recovery,8),
             DoubleToString(PF,8),
             IntegerToString(pontos),
             IntegerToString(ndd),
             benchmark_ok?benchmark:"desativado");
   FileClose(h);
}

//====================================================================
// MOTOR HÍBRIDO v3.5 — replay M1 + deals reais
//====================================================================
struct HDealEvent
{
   datetime time;
   ulong    ticket;
   long     posId;
   long     dealType;
   long     entry;
   double   volume;
   double   price;
   double   effect;
   string   symbol;
};

struct HActivePos
{
   long             posId;
   ENUM_POSITION_TYPE type;
   double           volume;
   double           openPriceVolume;
   string           symbol;
};

string HUniqueTradingSymbol(datetime inicio,datetime fim,bool &multi)
{
   multi=false;
   string symbols[];
   ArrayResize(symbols,0);
   if(!HistorySelect(0,fim)) return "";
   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong tk=HistoryDealGetTicket(i);
      if(tk==0 || !DealEhTrading(tk)) continue;
      datetime dt=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(dt<inicio || dt>fim) continue;
      string sym=HistoryDealGetString(tk,DEAL_SYMBOL);
      bool found=false;
      for(int j=0;j<ArraySize(symbols);j++)
         if(symbols[j]==sym) { found=true; break; }
      if(!found)
      {
         int n=ArraySize(symbols);
         ArrayResize(symbols,n+1);
         symbols[n]=sym;
      }
      if(ArraySize(symbols)>1) { multi=true; return ""; }
   }
   if(ArraySize(symbols)==1) return symbols[0];
   return "";
}

double HSyntheticPrice(const MqlRates &bar,int step,const int scenario)
{
   // 0=O-H-L-C, 1=O-L-H-C. Os knots são igualmente espaçados.
   double p0=bar.open, p1, p2, p3=bar.close;
   if(scenario==0)
   {
      p1=bar.high; p2=bar.low;
   }
   else
   {
      p1=bar.low; p2=bar.high;
   }
   if(step<=0) return p0;
   if(step==3) return p3;
   if(step==1) return p1;
   if(step==2) return p2;
   return p3;
}

double HInterpPrice(const MqlRates &bar,double frac,const int scenario)
{
   if(frac<=0.0) return bar.open;
   if(frac>=1.0) return bar.close;
   double p1=(scenario==0)?bar.high:bar.low;
   double p2=(scenario==0)?bar.low:bar.high;
   if(frac<1.0/3.0)
      return bar.open+(p1-bar.open)*(frac*3.0);
   if(frac<2.0/3.0)
      return p1+(p2-p1)*((frac-1.0/3.0)*3.0);
   return p2+(bar.close-p2)*((frac-2.0/3.0)*3.0);
}

int HFindActive(HActivePos &a[],long posId)
{
   for(int i=0;i<ArraySize(a);i++)
      if(a[i].posId==posId) return i;
   return -1;
}

void HApplyDeal(HDealEvent &e,HActivePos &active[],double &balance,string symbol)
{
   balance+=e.effect;
   if(e.symbol!=symbol || !DealEhTrading(e.ticket)) return;

   int idx=HFindActive(active,e.posId);
   if(e.entry==DEAL_ENTRY_IN)
   {
      if(idx<0)
      {
         int n=ArraySize(active);
         ArrayResize(active,n+1);
         active[n].posId=e.posId;
         active[n].type=(e.dealType==DEAL_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
         active[n].volume=e.volume;
         active[n].openPriceVolume=e.volume*e.price;
      }
      else
      {
         active[idx].openPriceVolume+=e.volume*e.price;
         active[idx].volume+=e.volume;
      }
   }
   else if(e.entry==DEAL_ENTRY_OUT || e.entry==DEAL_ENTRY_OUT_BY)
   {
      if(idx>=0)
      {
         double v=MathMin(e.volume,active[idx].volume);
         double avg=(active[idx].volume>EPSILON)?active[idx].openPriceVolume/active[idx].volume:e.price;
         active[idx].volume-=v;
         // Mantém aproximadamente o preço de custo restante. Em uma saída
         // parcial o preço médio da parcela remanescente permanece igual.
         active[idx].openPriceVolume=active[idx].volume*avg;
         if(active[idx].volume<=EPSILON)
         {
            int last=ArraySize(active)-1;
            for(int q=idx;q<last;q++)
               active[q]=active[q+1];
            ArrayResize(active,last);
         }
      }
   }
}

double HFloatingPL(HActivePos &active[],string symbol,double price)
{
   double pl=0.0;
   for(int i=0;i<ArraySize(active);i++)
   {
      if(active[i].symbol!=symbol || active[i].volume<=EPSILON) continue;
      double open=active[i].openPriceVolume/active[i].volume;
      double one=0.0;
      ENUM_ORDER_TYPE ot=(active[i].type==POSITION_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      if(OrderCalcProfit(ot,symbol,active[i].volume,open,price,one))
         pl+=one;
   }
   return pl;
}

bool HBuildEvents(datetime inicio,datetime fim,string symbol,HDealEvent &ev[])
{
   ArrayResize(ev,0);
   if(!HistorySelect(0,fim)) return false;
   int total=HistoryDealsTotal();
   datetime lastTime=0;
   bool ordered=true;
   for(int i=0;i<total;i++)
   {
      ulong tk=HistoryDealGetTicket(i);
      if(tk==0) continue;
      datetime dt=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);
      if(dt<inicio || dt>fim) continue;
      int n=ArraySize(ev);
      ArrayResize(ev,n+1);
      ev[n].time=dt;
      ev[n].ticket=tk;
      ev[n].posId=(long)HistoryDealGetInteger(tk,DEAL_POSITION_ID);
      ev[n].dealType=HistoryDealGetInteger(tk,DEAL_TYPE);
      ev[n].entry=HistoryDealGetInteger(tk,DEAL_ENTRY);
      ev[n].volume=HistoryDealGetDouble(tk,DEAL_VOLUME);
      ev[n].price=HistoryDealGetDouble(tk,DEAL_PRICE);
      ev[n].effect=EfeitoFinanceiroDeal(tk);
      ev[n].symbol=HistoryDealGetString(tk,DEAL_SYMBOL);
      if(lastTime>0 && dt<lastTime) ordered=false;
      lastTime=dt;
   }
   if(!ordered)
   {
      // Ordenação simples apenas como fallback para históricos fora de ordem.
      for(int i=1;i<ArraySize(ev);i++)
      {
         HDealEvent key=ev[i];
         int j=i-1;
         while(j>=0 && ev[j].time>key.time)
         {
            ev[j+1]=ev[j];
            j--;
         }
         ev[j+1]=key;
      }
   }
   return (ArraySize(ev)>0);
}

void HAddDD(double mag,double &dd[],int &n)
{
   if(mag<=EPSILON) return;
   int sz=ArraySize(dd);
   ArrayResize(dd,sz+1);
   dd[sz]=mag;
   n=sz+1;
}

bool HRunScenario(datetime inicio,datetime fim,string symbol,int scenario,int maxBars,
                  double &mdd,double &mddStar,int &nDD,double &coverage,string &status)
{
   mdd=0.0; mddStar=0.0; nDD=0; coverage=0.0; status="";
   HDealEvent ev[];
   if(!HBuildEvents(inicio,fim,symbol,ev)) { status="sem eventos"; return false; }

   MqlRates rates[];
   int nr=CopyRates(symbol,PERIOD_M1,inicio,fim,rates);
   if(nr<=0) { status="sem histórico M1"; return false; }
   int use=nr;
   if(maxBars>0 && use>maxBars) use=maxBars;
   if(use<2) { status="M1 insuficiente"; return false; }

   HActivePos active[];
   ArrayResize(active,0);
   int ei=0;
   double balance=0.0;
   double peak=0.0;
   double trough=0.0;
   bool inDD=false;

   // O saldo-base é tomado imediatamente antes do primeiro instante do
   // período; assim os deals ocorridos exatamente em "inicio" são aplicados
   // uma única vez pelo replay abaixo.
   if(inicio<=0 || !ReconstruirSaldoNaData(inicio-1,balance))
   {
      status="saldo base anterior ao início indisponível";
      return false;
   }

   peak=balance; trough=balance; inDD=false; nDD=0;
   double dd[]; ArrayResize(dd,0);
   for(int b=0;b<use;b++)
   {
      datetime bt=rates[b].time;
      datetime next=(b<use-1)?rates[b+1].time:fim;
      datetime endt=(next<fim?next:fim);
      long span=(long)(endt-bt);
      if(span<3) span=3;
      datetime knots[4];
      knots[0]=bt;
      knots[1]=bt+(datetime)(span/3);
      knots[2]=bt+(datetime)((2*span)/3);
      knots[3]=endt;
      for(int k=0;k<4;k++)
      {
         datetime kt=knots[k];
         while(ei<ArraySize(ev) && ev[ei].time<=kt)
         {
            HApplyDeal(ev[ei],active,balance,symbol);
            ei++;
         }
         double denom=(double)(endt-bt);
         double frac=(denom>0.0)?((double)(kt-bt)/denom):((double)k/3.0);
         double price=HInterpPrice(rates[b],frac,scenario);
         double equity=balance+HFloatingPL(active,symbol,price);
         if(equity>=peak-EPSILON)
         {
            if(inDD && peak>EPSILON)
               HAddDD((peak-trough)/peak,dd,nDD);
            if(equity>peak) peak=equity;
            trough=equity;
            inDD=false;
         }
         else
         {
            inDD=true;
            if(equity<trough) trough=equity;
         }
         if(peak>EPSILON)
         {
            double x=(peak-equity)/peak;
            if(x>mdd) mdd=x;
         }
      }
   }
   if(inDD && peak>EPSILON) HAddDD((peak-trough)/peak,dd,nDD);
   if(nDD<=0) { status="nenhum drawdown"; return false; }
   mddStar=TransformarParaMDDestrela(mdd);
   string det=""; bool bok=false;
   double bayes=MDDStarBayesiano(dd,nDD,topK,det,bok);
   if(bayes>mddStar) mddStar=bayes;
   coverage=(double)use/(double)MathMax(1,nr)*100.0;
   status=bok?"ok":"MDD medido; Bayes limitado";
   return true;
}

bool CalcularHibridoM1(datetime inicio,datetime fim,int maxBars,ResultadoHibrido &r)
{
   ZeroMemory(r);
   r.valido=false;
   r.multiativo=false;
   r.status="";
   string symbol=HUniqueTradingSymbol(inicio,fim,r.multiativo);
   if(r.multiativo)
   {
      r.status="conta multiativo: replay híbrido completo não aplicado; fallback v3.4";
      return false;
   }
   if(symbol=="")
   {
      r.status="nenhum símbolo de trading elegível";
      return false;
   }
   r.simbolo=symbol;
   double bestStar=-1.0,bestMdd=0.0; int bestN=0; double bestCov=0.0; string bestPath="";
   if(incluir_caminho_ohlc_1)
   {
      double m=0,ms=0,c=0; int n=0; string st="";
      if(HRunScenario(inicio,fim,symbol,0,maxBars,m,ms,n,c,st))
      {
         if(ms>bestStar){bestStar=ms;bestMdd=m;bestN=n;bestCov=c;bestPath="O-H-L-C";}
      }
   }
   if(incluir_caminho_ohlc_2)
   {
      double m=0,ms=0,c=0; int n=0; string st="";
      if(HRunScenario(inicio,fim,symbol,1,maxBars,m,ms,n,c,st))
      {
         if(ms>bestStar){bestStar=ms;bestMdd=m;bestN=n;bestCov=c;bestPath="O-L-H-C";}
      }
   }
   if(bestStar<=0.0)
   {
      r.status="replay M1 híbrido indisponível";
      return false;
   }
   r.valido=true;
   r.mdd=bestMdd;
   r.mdd_star_medido=TransformarParaMDDestrela(bestMdd);
   r.mdd_star_bayes=bestStar;
   r.n_dd=bestN;
   r.cobertura_m1=bestCov;
   r.caminho=bestPath;
   r.status="ok";
   return true;
}

//====================================================================
// OnStart
//====================================================================
void OnStart()
{
   Print("=== Índice Melão v3.5 iniciado ===");

   if(segundos_periodo<=0)
   {
      Print("Erro: segundos_periodo deve ser > 0.");
      return;
   }
   if(topK<1)
   {
      Print("Erro: topK deve ser >= 1.");
      return;
   }
   if(numero_janelas<2)
   {
      Print("Erro: numero_janelas deve ser >= 2.");
      return;
   }
   if(inflacao_anual<=-1.0)
   {
      Print("Erro: inflacao_anual deve ser maior que -100%.");
      return;
   }

   double fator=fator_ponderacao;
   if(fator<=0.0 || fator>1.0)
   {
      if(ponderar_regressao)
         Print("Aviso: fator_ponderacao inválido; usando 0.95.");
      fator=0.95;
   }

   datetime fim=(tempo_fim==0)?TimeCurrent():tempo_fim;
   if(fim>TimeCurrent()) fim=TimeCurrent();

   datetime inicio=tempo_inicio;
   if(inicio==0)
   {
      if(!EncontrarPrimeiroDealTrading(fim,inicio))
      {
         Print("Nenhum deal de trading encontrado.");
         return;
      }
   }

   if(inicio>=fim)
   {
      Print("Período inválido: início >= fim.");
      return;
   }

   //=================================================================
   // 1) Construir série
   //=================================================================
   SerieTemporal st;
   double saldo_base=0.0;
   int deals_ok=0,deals_ig=0;
   bool serie_ok=false;

   if(modo_serie==MODO_POR_DEAL)
      serie_ok=ConstruirSeriePorDeal(st,inicio,fim,saldo_inicial_manual,
                                     saldo_base,deals_ok,deals_ig);
   else
      serie_ok=ConstruirSerieTemporal(st,inicio,fim,segundos_periodo,
                                      saldo_inicial_manual,
                                      saldo_base,deals_ok,deals_ig);

   if(!serie_ok || st.tamanho<2)
   {
      Print("Falha ao construir série histórica.");
      return;
   }

   //=================================================================
   // 2) Totais reais do período
   //=================================================================
   TotaisConta totais;
   if(!CalcularTotaisPeriodo(st.tempos[0],fim,totais))
   {
      Print("Falha ao calcular totais do período.");
      return;
   }

   //=================================================================
   // 3) Benchmark opcional, sem look-ahead
   //=================================================================
   bool benchmark_ok=false;
   string aviso_benchmark="";
   if(benchmark_symbol!="")
   {
      benchmark_ok=SubtrairBenchmark(st,benchmark_symbol,benchmark_tf);
      if(!benchmark_ok)
      {
         aviso_benchmark="Benchmark solicitado, mas não aplicado. Retorno bruto mantido.";
         Print(aviso_benchmark);
      }
   }

   //=================================================================
   // 4) Retorno pela regressão
   //=================================================================
   double R=0.0,R_periodo=0.0,T=0.0;
   if(!CalcularRetornoRegressao(st,ponderar_regressao,fator,R,R_periodo,T))
   {
      Print("Regressão inválida.");
      return;
   }

   //=================================================================
   // 5) Sigma auxiliar
   //=================================================================
   double passos_ano=0.0;
   double sigma_anual=0.0;
   if(calcular_sigma)
      sigma_anual=CalcularSigmaAnualizado(st,passos_ano);

   //=================================================================
   // 6) Drawdowns
   //=================================================================
   double dd_frac[];
   int n_dd=0;
   CalcularEpisodiosDrawdown(st.saldos,st.tamanho,dd_frac,n_dd);

   double maior_mdd=0.0;
   for(int i=0;i<n_dd;i++)
      if(dd_frac[i]>maior_mdd) maior_mdd=dd_frac[i];

   double mdd_star_medido=TransformarParaMDDestrela(maior_mdd);

   //=================================================================
   // 6.5) Motor híbrido v3.5
   //      A rentabilidade R/T continua vindo da série v3.4.
   //      O risco pode usar replay M1 + caminhos intrabar OHLC quando
   //      todos os trades do período pertencem a um único símbolo.
   //      Em multiativo, o fallback permanece o MDD v3.4.
   //=================================================================
   ResultadoHibrido rh;
   bool hybrid_ok=false;
   if(usar_hibrido_m1 && modo_serie==MODO_HIBRIDO)
      hybrid_ok=CalcularHibridoM1(st.tempos[0],fim,max_barras_m1_hibrido,rh);

   // Mantém o MDD observado como referência e só substitui o risco usado
   // no MeI quando o estimador híbrido produzir uma estimativa superior.
   if(hybrid_ok && rh.mdd_star_bayes > mdd_star_medido)
   {
      maior_mdd=rh.mdd;
      mdd_star_medido=rh.mdd_star_medido;
   }

   //=================================================================
   // 7) Bayes MDD*
   //=================================================================
   int topK_recomendado=5;
   if(n_dd>=2)
      topK_recomendado=(int)MathCeil(MathSqrt((double)n_dd));
   if(topK_recomendado<2) topK_recomendado=2;

   string aviso_topK="";
   if(n_dd>=2 && topK<topK_recomendado)
      aviso_topK=StringFormat("Sugestão heurística: %d episódios -> topK=%d pode ser mais estável (atual=%d).",
                              n_dd,topK_recomendado,topK);

   string det_bayes="";
   bool bayes_ok=false;
   double MDDstar=MDDStarBayesiano(dd_frac,n_dd,topK,det_bayes,bayes_ok);
   if(hybrid_ok && rh.mdd_star_bayes>MDDstar)
   {
      MDDstar=rh.mdd_star_bayes;
      det_bayes+="\n[MODO HÍBRIDO v3.5] MDD* híbrido mais conservador aplicado ao MeI.\n";
   }

   //=================================================================
   // 8) MeI
   //=================================================================
   double lnR=0.0,lnI=0.0,lnD=0.0;
   bool okR=Ln1pSeguro(R,lnR);
   bool okI=Ln1pSeguro(inflacao_anual,lnI);
   bool okD=Ln1pSeguro(MDDstar,lnD);

   bool MeI_valido=(okR && okI && okD && T>0.0 && MathAbs(lnD)>EPSILON);
   double MeI=MeI_valido ? ((lnR-lnI)/lnD*MathSqrt(T)) : 0.0;

   //=================================================================
   // 9) Projeção para 1 ano via sqrt(T)
   //     Isto é explicitamente uma extensão operacional baseada na
   //     discussão da Seção VII, não uma nova equação formal do artigo.
   //=================================================================
   double MDDstar_proj=0.0;
   double MDD_proj=0.0;
   double MeI_proj=0.0;
   bool proj_ok=false;

   if(MeI_valido && T>0.0 && T<1.0)
   {
      double fator_t=MathSqrt(1.0/T);
      MDDstar_proj=MDDstar*fator_t;
      MDD_proj=ConverterMDDStarParaMDD(MDDstar_proj);
      double lnDproj=MathLog(1.0+MDDstar_proj);
      if(lnDproj>EPSILON)
      {
         MeI_proj=(lnR-lnI)/lnDproj;
         proj_ok=true;
      }
   }

   //=================================================================
   // 10) Profit Factor e Recovery Factor
   //     Sempre sobre a mesma base do período e, quando benchmark está
   //     ligado, o benchmark é aplicado também ao resultado temporal.
   //=================================================================
   double gross_profit=0.0,gross_loss=0.0;
   if(!HistorySelect(0,fim))
      Print("Aviso: não foi possível recarregar histórico para PF.");
   else
   {
      int total=HistoryDealsTotal();
      for(int i=0;i<total;i++)
      {
         ulong tk=HistoryDealGetTicket(i);
         if(tk==0 || !DealEhTrading(tk)) continue;
         datetime dt=(datetime)HistoryDealGetInteger(tk,DEAL_TIME);
         if(dt<st.tempos[0] || dt>fim) continue;

         double liq=EfeitoFinanceiroDeal(tk);
         if(liq>0.0) gross_profit+=liq;
         else if(liq<0.0) gross_loss+=liq;
      }
   }

   double profit_factor=(MathAbs(gross_loss)>EPSILON)?gross_profit/MathAbs(gross_loss):0.0;

   // Recovery Factor auxiliar: usa a mesma série que gerou o MDD.
   // Quando benchmark está ativo, o numerador passa a ser o resultado
   // líquido da série benchmark-ajustada, mantendo a mesma base do risco.
   double lucro_referencia = benchmark_ok
                            ? (st.saldos[st.tamanho-1]-st.saldos[0])
                            : totais.resultado_liquido_trading;
   double recovery_factor=0.0;
   if(maior_mdd>EPSILON && st.saldos[0]>EPSILON)
      recovery_factor=lucro_referencia/(st.saldos[0]*maior_mdd);

   //=================================================================
   // 11) Janelas de estabilidade
   //=================================================================
   JanelaInfo janelas[];
   ArrayResize(janelas,numero_janelas);
   int janelas_validas=0;

   if(calcular_janelas && st.tamanho>=numero_janelas*3)
   {
      for(int j=0;j<numero_janelas;j++)
      {
         int ini=0,fim_idx=0;
         if(modo_serie==MODO_TEMPORAL)
         {
            // divisão uniforme por TEMPO, reduzindo viés de densidade dos pontos
            datetime t0=st.tempos[0];
            datetime t1=st.tempos[st.tamanho-1];
            long dur=t1-t0;
            datetime wi=t0+(datetime)((long)j*dur/numero_janelas);
            datetime wf=t0+(datetime)((long)(j+1)*dur/numero_janelas);
            ini=EncontrarIndicePorTempo(st,wi);
            fim_idx=EncontrarIndicePorTempo(st,wf)+1;
            if(ini<0) ini=0;
            if(fim_idx>st.tamanho) fim_idx=st.tamanho;
         }
         else
         {
            int bloco=st.tamanho/numero_janelas;
            ini=j*bloco;
            fim_idx=(j==numero_janelas-1)?st.tamanho:(j+1)*bloco;
         }

         if(fim_idx-ini<3) continue;

         double mei_j=0.0;
         JanelaInfo ji;
         int topK_j=MathMax(1,MathMin(topK,5));
         if(CalcularMeIJanela(st,ini,fim_idx,inflacao_anual,
                             ponderar_regressao,fator,topK_j,mei_j,ji))
         {
            janelas[j]=ji;
            janelas_validas++;
         }
      }
   }

   //=================================================================
   // 12) Diagnóstico de estabilidade
   //=================================================================
   double media_j=0.0,dp_j=0.0,cv_j=0.0;
   if(janelas_validas>=2)
   {
      double vals[];
      ArrayResize(vals,janelas_validas);
      int q=0;
      for(int j=0;j<numero_janelas;j++)
      {
         if(janelas[j].status=="ok" || janelas[j].status=="MDD* medido (sem Bayes suficiente)")
            vals[q++]=janelas[j].mei;
      }
      if(q>0)
      {
         for(int i=0;i<q;i++) media_j+=vals[i];
         media_j/=q;
         dp_j=DesvioPadraoAmostral(vals,q);
         if(MathAbs(media_j)>EPSILON) cv_j=100.0*dp_j/MathAbs(media_j);
      }
   }

   //=================================================================
   // 13) RELATÓRIO
   //=================================================================
   string modo_txt=(modo_serie==MODO_TEMPORAL)?
                    StringFormat("Temporal (%d s/ponto)",segundos_periodo):
                    "Por deal (auditoria; não recomendado para comparação de frequência)";

   string bench_txt;
   if(benchmark_symbol=="") bench_txt="desativado";
   else if(benchmark_ok) bench_txt=benchmark_symbol+" (aplicado; sem look-ahead)";
   else bench_txt=benchmark_symbol+" (FALHOU; retorno bruto usado)";

   string rel="";
   rel+="RELATÓRIO DO ÍNDICE MELÃO (MeI) v3.5\n";
   rel+="==============================================\n";
   rel+=StringFormat("Início                : %s\n",TimeToString(st.tempos[0],TIME_DATE|TIME_MINUTES));
   rel+=StringFormat("Fim                   : %s\n",TimeToString(st.tempos[st.tamanho-1],TIME_DATE|TIME_MINUTES));
   rel+=StringFormat("T (anos)              : %.8f\n",T);
   rel+=StringFormat("Pontos na série       : %d\n",st.tamanho);
   rel+=StringFormat("Modo da série         : %s\n",modo_txt);
   rel+=StringFormat("Deals de trading      : %d\n",deals_ok);
   rel+=StringFormat("Deals não-trading     : %d\n",deals_ig);
   rel+=StringFormat("Saldo base reconstruído: %.10f\n",saldo_base);
   rel+=StringFormat("Benchmark             : %s\n",bench_txt);

   rel+="\n--- RESULTADO LÍQUIDO DA CONTA ---\n";
   rel+=StringFormat("Lucro dos trades      : %.2f\n",totais.resultado_trading);
   rel+=StringFormat("Swap                  : %.2f\n",totais.swap);
   rel+=StringFormat("Comissão              : %.2f\n",totais.comissao);
   rel+=StringFormat("Fee                   : %.2f\n",totais.fee);
   rel+=StringFormat("Resultado trading net : %.2f\n",totais.resultado_liquido_trading);
   rel+=StringFormat("Eventos externos      : %.2f\n",totais.externos);

   if(T<T_MINIMO_AVISO)
   {
      rel+="\n*** AVISO: histórico inferior a 3 meses.\n";
      rel+="    R anualizado e projeção de longo prazo são estatisticamente instáveis.\n";
      rel+="    Use R do período como leitura primária. ***\n";
   }

   if(modo_serie==MODO_POR_DEAL)
   {
      rel+="\n*** NOTA METODOLÓGICA: modo por deal ativo.\n";
      rel+="    A regressão dá um ponto por deal e, portanto, uma estratégia com\n";
      rel+="    mais trades pode receber peso maior. Para ranking entre estratégias,\n";
      rel+="    prefira o modo Temporal. ***\n";
   }

   rel+="\n--- RETORNO ---\n";
   rel+=StringFormat("R do período (regressão): %.8f%%\n",R_periodo*100.0);
   rel+=StringFormat("R anualizado           : %.10f (%.6f%% a.a.)\n",R,R*100.0);
   rel+=StringFormat("Inflação anual         : %.8f (%.6f%% a.a.)\n",inflacao_anual,inflacao_anual*100.0);
   if(calcular_sigma)
   {
      rel+=StringFormat("Sigma anualizado       : %.10f\n",sigma_anual);
      rel+=StringFormat("Pontos/ano para sigma  : %.4f\n",passos_ano);
   }

   rel+="\n--- RISCO / DRAWDOWN ---\n";
   rel+=StringFormat("Episódios de drawdown  : %d\n",n_dd);
   rel+=StringFormat("MDD medido             : %.8f%%\n",maior_mdd*100.0);
   rel+=StringFormat("MDD* medido            : %.12f\n",mdd_star_medido);
   rel+=StringFormat("MDD* usado no MeI      : %.12f\n",MDDstar);
   rel+=StringFormat("MDD equivalente usado  : %.8f%%\n",ConverterMDDStarParaMDD(MDDstar)*100.0);

   if(modo_serie==MODO_HIBRIDO)
   {
      rel+="\n--- MOTOR HÍBRIDO v3.5 ---\n";
      if(hybrid_ok)
      {
         rel+=StringFormat("Símbolo replayado      : %s\n",rh.simbolo);
         rel+=StringFormat("Caminho intrabar       : %s\n",rh.caminho);
         rel+=StringFormat("MDD híbrido medido     : %.8f%%\n",rh.mdd*100.0);
         rel+=StringFormat("MDD* híbrido medido    : %.12f\n",rh.mdd_star_medido);
         rel+=StringFormat("MDD* híbrido Bayes     : %.12f\n",rh.mdd_star_bayes);
         rel+=StringFormat("Episódios híbridos     : %d\n",rh.n_dd);
         rel+=StringFormat("Cobertura M1            : %.4f%%\n",rh.cobertura_m1);
         rel+="Os pontos intrabar são sintéticos a partir do OHLC M1; não são ticks históricos.\n";
      }
      else
      {
         rel+="Híbrido não aplicado: "+rh.status+"\n";
         rel+="Fallback: MDD da série v3.4.\n";
      }
   }

   if(aviso_topK!="") rel+="\nAviso: "+aviso_topK+"\n";

   rel+="\n--- ESTIMATIVA BAYESIANA DO MDD* ---\n";
   rel+="Posições percentílicas calculadas sobre N = episódios de drawdown.\n";
   rel+=det_bayes;

   if(!bayes_ok)
      rel+="NOTA: a amostra é pequena; o MDD* medido foi usado sem extrapolação Bayesiana confiável.\n";

   rel+="\n--- ÍNDICE MELÃO ---\n";
   if(MeI_valido)
      rel+=StringFormat(">>> MeI = %.15f <<<\n",MeI);
   else
   {
      rel+=">>> MeI = INVÁLIDO <<<\n";
      if(!okR) rel+="Causa: ln(1+R) inválido.\n";
      if(!okI) rel+="Causa: ln(1+inflação) inválido.\n";
      if(!okD) rel+="Causa: ln(1+MDD*) inválido ou MDD* zero.\n";
   }

   rel+="\n--- PROJEÇÃO 1 ANO (sqrt(T)) ---\n";
   rel+="Extensão operacional baseada na discussão temporal da Seção VII; não é apresentada aqui como nova equação formal do artigo.\n";
   if(proj_ok)
   {
      rel+=StringFormat("Fator de escala         : %.8f\n",MathSqrt(1.0/T));
      rel+=StringFormat("MDD* projetado          : %.12f\n",MDDstar_proj);
      rel+=StringFormat("MDD projetado equivalente: %.8f%%\n",MDD_proj*100.0);
      rel+=StringFormat("MeI projetado 1 ano     : %.12f\n",MeI_proj);
   }
   else
      rel+="Não aplicável ou inválido para este histórico.\n";

   rel+="\n--- PERFORMANCE AUXILIAR ---\n";
   rel+=StringFormat("Gross Profit            : %.2f\n",gross_profit);
   rel+=StringFormat("Gross Loss              : %.2f\n",gross_loss);
   rel+=StringFormat("Profit Factor           : %.8f\n",profit_factor);
   rel+=StringFormat("Recovery Factor         : %.8f\n",recovery_factor);

   rel+="\n--- ESTABILIDADE POR JANELAS ---\n";
   if(!calcular_janelas)
      rel+="Desativado.\n";
   else if(janelas_validas<2)
      rel+="Amostra insuficiente para diagnóstico por janelas.\n";
   else
   {
      for(int j=0;j<numero_janelas;j++)
      {
         if(janelas[j].pontos<=0) continue;
         rel+=StringFormat("Janela %d: %s -> %s | pontos=%d | MeI=%.8f | R=%.4f%% a.a. | MDD=%.4f%% | %s\n",
                           j+1,
                           TimeToString(janelas[j].inicio,TIME_DATE|TIME_MINUTES),
                           TimeToString(janelas[j].fim,TIME_DATE|TIME_MINUTES),
                           janelas[j].pontos,
                           janelas[j].mei,
                           janelas[j].R*100.0,
                           janelas[j].mdd*100.0,
                           janelas[j].status);
      }
      rel+=StringFormat("Média MeI das janelas  : %.8f\n",media_j);
      rel+=StringFormat("DP das janelas         : %.8f\n",dp_j);
      rel+=StringFormat("CV das janelas         : %.4f%%\n",cv_j);
      rel+="Diagnóstico CV: heurístico, não faz parte da fórmula do MeI.\n";
      if(cv_j<30.0)
         rel+="Interpretação auxiliar: baixa dispersão entre janelas.\n";
      else if(cv_j<70.0)
         rel+="Interpretação auxiliar: dispersão moderada entre janelas.\n";
      else
         rel+="Interpretação auxiliar: alta dispersão entre janelas; investigar dependência temporal/sorte.\n";
   }

   rel+="\n--- FÓRMULAS PRINCIPAIS ---\n";
   rel+="MDD* = MDD / (1-MDD)\n";
   rel+="MeI = [ln(1+R)-ln(1+i)] / ln(1+MDD*) × sqrt(T)\n";
   rel+="R = exp(inclinação da regressão ln(saldo) x tempo) - 1\n";
   rel+="\n--- LIMITAÇÕES IMPORTANTES ---\n";
   rel+="1. O MDD v3.4 é o MDD da série histórica reconstruída nos pontos disponíveis.\n";
   rel+="2. O híbrido v3.5 adiciona replay intraminuto com deals reais + OHLC M1 para contas de um único símbolo.\n";
   rel+="3. Os caminhos O-H-L-C e O-L-H-C são sintéticos; não representam ticks históricos reais.\n";
   rel+="4. Em contas multiativo, o híbrido é desativado e o MDD v3.4 permanece como fallback.\n";
   rel+="5. Benchmark é opcional e usa somente o último candle fechado disponível até cada ponto.\n";
   rel+="6. A estimativa Bayesiana é uma operacionalização da Seção VII, não uma distribuição universal garantida.\n";
   rel+="7. CV e sugestão de topK são diagnósticos heurísticos adicionais.\n";

   Print(rel);

   //=================================================================
   // 14) Arquivo TXT
   //=================================================================
   if(gravarArquivo)
   {
      string nome_arq="IndiceMelao_v3.5_resultado.txt";
      EscreverArquivo(nome_arq,rel);
      string caminho=TerminalInfoString(TERMINAL_DATA_PATH)+"\\MQL5\\Files\\"+nome_arq;
      if(abrirArquivoAoFinal) AbrirArquivo(caminho);
   }

   //=================================================================
   // 15) CSV histórico
   //=================================================================
   if(gravarCSVHistorico)
   {
      string csv="IndiceMelao_historico.csv";
      GravarCSVHistorico(csv,T,R,R_periodo,maior_mdd,MDDstar,MeI,
                         MeI_proj,sigma_anual,recovery_factor,profit_factor,
                         st.tamanho,n_dd,benchmark_ok,benchmark_symbol,
                         modo_serie==MODO_TEMPORAL?"temporal":
                         (modo_serie==MODO_HIBRIDO?"hibrido":"por_deal"));
   }

   Print("=== Índice Melão v3.5 finalizado ===");
}
