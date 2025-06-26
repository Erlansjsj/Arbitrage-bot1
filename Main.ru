import os
import asyncio
import aiohttp
import time
import hmac
import hashlib
import json
from decimal import Decimal, getcontext
from typing import Dict, List
from collections import defaultdict
from urllib.parse import urlencode
from telegram import Bot
import networkx as nx

# === Настройки точности вычислений ===
getcontext().prec = 20

# === Загрузка переменных окружения ===
from dotenv import load_dotenv
load_dotenv()

# === Конфигурация ===
BINANCE_API_KEY = os.getenv("BINANCE_API_KEY")
BINANCE_API_SECRET = os.getenv("BINANCE_API_SECRET")
TELEGRAM_TOKEN = os.getenv("TELEGRAM_TOKEN")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID")

BASE_URL = "https://testnet.binance.vision "
WS_BASE = "wss://testnet.binance.vision/ws"

INITIAL_SYMBOLS = [
    "btcusdt", "btctry", "ethusdt", "ethttry",
    "bnbusdt", "bnbtry", "ltcusdt", "dogeusdt", "solusdt",
    "usdttry", "xrpusdt", "xrptry"
]

COMMISSION_RATE = Decimal('0.001')  # 0.1%
RECV_WINDOW = 5000  # ms
MIN_PROFIT_THRESHOLD = Decimal('0.003')  # 0.3%
POSITION_LIMIT_USDT = Decimal('100')  # Макс. объем одной сделки
CHECK_INTERVAL = 10  # Пауза между итерациями

# === Telegram Notifier ===
class TelegramNotifier:
    def __init__(self, token: str, chat_id: str):
        self.bot = Bot(token=token)
        self.chat_id = chat_id

    async def send_message(self, text: str) -> None:
        try:
            await self.bot.send_message(chat_id=self.chat_id, text=text)
        except Exception as e:
            print(f"Telegram error: {e}")

# === Binance REST API клиент ===
class BinanceClient:
    def __init__(self, api_key: str, api_secret: str):
        self.api_key = api_key
        self.api_secret = api_secret
        self.session = aiohttp.ClientSession()
        self.server_offset = 0  # Разница между локальным временем и серверным

    def _sign(self, params: dict) -> str:
        query_string = urlencode(params)
        return hmac.new(
            self.api_secret.encode('utf-8'),
            query_string.encode('utf-8'),
            hashlib.sha256
        ).hexdigest()

    async def sync_server_time(self) -> None:
        url = f"{BASE_URL}/api/v3/time"
        try:
            async with self.session.get(url) as resp:
                data = await resp.json()
                server_time = data['serverTime']
                local_time = int(time.time() * 1000)
                self.server_offset = server_time - local_time
                print(f"[Sync] Server time offset: {self.server_offset} ms")
        except Exception as e:
            print(f"Ошибка синхронизации времени: {e}")

    async def _request(self, method: str, path: str, params: dict = None) -> Optional[dict]:
        if params is None:
            params = {}

        if not hasattr(self, 'server_offset'):
            await self.sync_server_time()

        local_timestamp = int(time.time() * 1000)
        params['timestamp'] = local_timestamp + self.server_offset
        params['recvWindow'] = RECV_WINDOW
        params['signature'] = self._sign(params)

        headers = {"X-MBX-APIKEY": self.api_key}
        url = BASE_URL + path

        try:
            async with self.session.request(method, url, params=params, headers=headers) as resp:
                data = await resp.json()
                if resp.status != 200:
                    print(f"Binance API error {resp.status}: {data}")
                    return None
                return data
        except Exception as e:
            print(f"Request error: {e}")
            return None

    async def get_all_prices(self) -> Optional[list]:
        return await self._request("GET", "/api/v3/ticker/price")

    async def create_order(self, symbol: str, side: str, quantity: Decimal, price: Optional[Decimal] = None) -> Optional[dict]:
        params = {
            "symbol": symbol.upper(),
            "side": side.upper(),
            "type": "MARKET",
            "quantity": str(quantity),
        }
        if price:
            params["type"] = "LIMIT"
            params["price"] = str(price)
            params["timeInForce"] = "GTC"
        return await self._request("POST", "/api/v3/order", params)

    async def close(self) -> None:
        await self.session.close()

# === Арбитражный движок ===
class ArbitrageEngine:
    def __init__(self, symbols: List[str], commission_rate: Decimal):
        self.symbols = symbols
        self.commission_rate = commission_rate
        self.graph = nx.DiGraph()

    def build_graph(self, prices: Dict[str, Decimal]) -> None:
        self.graph.clear()
        for symbol, price in prices.items():
            base, quote = symbol[:3].upper(), symbol[3:].upper()
            if base and quote:
                weight = math.log(float(price) * float(1 - self.commission_rate))
                self.graph.add_edge(quote, base, weight=-weight)
                self.graph.add_edge(base, quote, weight=math.log(float(1 / price) * float(1 - self.commission_rate)))

    def find_arbitrage_cycle(self) -> Optional[List[str]]:
        try:
            cycle = nx.find_negative_cycle(self.graph, source=None)
            if cycle:
                return cycle
        except nx.NetworkXError:
            pass
        return None

# === Менеджер рисков и позиций ===
class RiskManager:
    def __init__(self, position_limit: Decimal):
        self.position_limits = defaultdict(lambda: position_limit)
        self.lock = asyncio.Lock()

    async def update_profitability(self, symbol: str, profit: Decimal) -> None:
        if profit > MIN_PROFIT_THRESHOLD:
            print(f"[Profitable] {symbol} | Profit: {profit * Decimal(100):.2f}%")

    def get_profitable_symbols(self, all_symbols: List[str]) -> List[str]:
        return all_symbols  # Можно добавить фильтрацию после анализа убытков

# === Основной бот ===
class ArbitrageMarketMakingBot:
    def __init__(self):
        self.client = BinanceClient(BINANCE_API_KEY, BINANCE_API_SECRET)
        self.telegram = TelegramNotifier(TELEGRAM_TOKEN, TELEGRAM_CHAT_ID)
        self.arbitrage_engine = ArbitrageEngine(INITIAL_SYMBOLS, COMMISSION_RATE)
        self.risk_manager = RiskManager(POSITION_LIMIT_USDT)
        self.prices = {}  # {symbol: Decimal}

    async def fetch_all_prices(self) -> None:
        try:
            data = await self.client.get_all_prices()
            for item in 
                sym = item["symbol"].lower()
                if sym in INITIAL_SYMBOLS:
                    self.prices[sym] = Decimal(item["price"])
        except Exception as e:
            print(f"Ошибка получения цен: {e}")

    async def check_triangular_arbitrage(self) -> None:
        await self.fetch_all_prices()
        self.arbitrage_engine.build_graph(self.prices)
        cycle = self.arbitrage_engine.find_arbitrage_cycle()
        if cycle:
            try:
                profit = Decimal(1)
                for i in range(len(cycle) - 1):
                    src, dst = cycle[i], cycle[i+1]
                    symbol = f"{dst.lower()}{src.lower()}"
                    price = self.prices.get(symbol, Decimal(1))
                    if dst == src:
                        continue
                    profit *= Decimal(1) / price
                profit *= (Decimal(1) - COMMISSION_RATE) ** len(cycle)
                actual_profit = profit - Decimal(1)
                if actual_profit > MIN_PROFIT_THRESHOLD:
                    message = (
                        f"✅ Арбитраж найден!\n"
                        f"Цикл: {' → '.join(cycle)}\n"
                        f"Прибыль: {actual_profit * Decimal(100):.3f}%"
                    )
                    print(message)
                    await self.telegram.send_message(message)

                    # Выставление ордеров
                    await self.execute_arbitrage_cycle(cycle)
            except Exception as e:
                print(f"Ошибка анализа арбитража: {e}")

    async def execute_arbitrage_cycle(self, cycle: List[str]):
        """Выполнение цепочки ордеров"""
        for i in range(len(cycle) - 1):
            src, dst = cycle[i], cycle[i+1]
            symbol = f"{dst.lower()}{src.lower()}"
            price = self.prices.get(symbol, Decimal(1))
            qty = POSITION_LIMIT_USDT / price
            response = await self.client.create_order(symbol=symbol, side="BUY", quantity=qty)
            if response:
                print(f"✅ Выставлен ордер: BUY {symbol.upper()} @ {price} x {qty}")
            else:
                print(f"❌ Не удалось выставить ордер: {symbol.upper()}")

    async def main_loop(self) -> None:
        await self.client.sync_server_time()

        while True:
            try:
                await self.check_triangular_arbitrage()
                await asyncio.sleep(CHECK_INTERVAL)
            except KeyboardInterrupt:
                print("Остановка бота...")
                break
            except Exception as e:
                print(f"Ошибка в основном цикле: {e}")

    async def close(self) -> None:
        await self.client.close()

async def main():
    bot = ArbitrageMarketMakingBot()
    try:
        await bot.main_loop()
    finally:
        await bot.close()

if __name__ == "__main__":
    asyncio.run(main())
