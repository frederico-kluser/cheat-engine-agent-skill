/*
 * alvo.c — programa-alvo determinístico para testar a skill do Cheat Engine.
 *
 * Imita um "jogo": um ponteiro estático (g_mundo) aponta para uma struct no
 * heap, que aponta para o jogador. A cada tick a função dano() tira 1 de vida
 * (é a instrução que o "ce watch" deve achar) e o estado vai para stdout.
 *
 *   gcc -O1 -g -o alvo alvo.c && ./alvo [intervalo_ms]
 *
 * Linhas de saída (uma por tick):
 *   vida=97 energia=50.50 ouro=1234.50 contador=1003 nome=Heroi
 * Na partida imprime os endereços reais, para os testes conferirem:
 *   PID=123 &vida=0x... &g_mundo=0x... &g_contador=0x... &assinatura=0x...
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    int vida;
    float energia;
    double ouro;
    char nome[32];
} Jogador;

typedef struct {
    Jogador *jogador;
    int nivel;
} Mundo;

Mundo *g_mundo;                    /* ponteiro estático (base de cadeia) */
volatile int g_contador = 1000;    /* inteiro estático (.data) */
const unsigned char g_assinatura[] = {0xDE, 0xAD, 0xBE, 0xEF, 0x13, 0x37, 0xC0, 0xDE,
                                      0x41, 0x47, 0x45, 0x4E, 0x54, 0x45, 0x21, 0x00};

__attribute__((noinline)) void dano(Jogador *j, int qtd) {
    j->vida -= qtd;
}

int main(int argc, char **argv) {
    int intervalo = argc > 1 ? atoi(argv[1]) : 500;
    setvbuf(stdout, NULL, _IOLBF, 0);

    g_mundo = calloc(1, sizeof(Mundo));
    g_mundo->jogador = calloc(1, sizeof(Jogador));
    g_mundo->nivel = 7;
    Jogador *j = g_mundo->jogador;
    j->vida = 100;
    j->energia = 50.5f;
    j->ouro = 1234.5;
    strcpy(j->nome, "Heroi");

    printf("PID=%d &vida=%p &g_mundo=%p &g_contador=%p &assinatura=%p &dano=%p\n",
           getpid(), (void *)&j->vida, (void *)&g_mundo, (void *)&g_contador,
           (void *)g_assinatura, (void *)dano);

    for (;;) {
        usleep(intervalo * 1000);
        dano(g_mundo->jogador, 1);
        if (j->vida <= 0)
            j->vida = 100;
        g_contador++;
        printf("vida=%d energia=%.2f ouro=%.2f contador=%d nome=%s sig=%02X\n",
               j->vida, j->energia, j->ouro, g_contador, j->nome, g_assinatura[0]);
    }
    return 0;
}
