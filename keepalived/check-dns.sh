#!/bin/sh
# Retourne 0 seulement si le Pi-hole qui partage ce namespace réseau répond.
# dig sort 0 dès qu'une réponse DNS arrive (NOERROR ou NXDOMAIN).
# Un timeout ou un refus de connexion fait perdre la VIP.
/usr/bin/dig +time=1 +tries=1 +retry=0 @127.0.0.1 pi.hole A >/dev/null 2>&1
