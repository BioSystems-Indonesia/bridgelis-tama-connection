import 'reflect-metadata';
import {
  Controller, Delete, Get, Injectable, Module, Param, Post, Body, Req, Res,
} from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import type { Request, Response } from 'express';
import { LisClient, LisError, type OrderRequest, type ResultEvent } from 'bridgelis-tama-connection';

@Injectable()
export class LisService {
  readonly lis = new LisClient(); // config from process.env
  readonly events: Array<{ order_id: string; is_final: boolean }> = [];
  constructor() {
    this.lis.onResult(async (e: ResultEvent) => { this.events.push({ order_id: e.order_id, is_final: e.is_final }); });
  }
  async run<T>(res: Response, fn: () => Promise<T>): Promise<void> {
    try { res.status(200).json(await fn()); }
    catch (e) {
      if (e instanceof LisError) { res.status(e.retryable ? 503 : 422).json({ error: e.code, retryable: e.retryable, httpStatus: e.httpStatus, message: e.message }); return; }
      res.status(500).json({ error: 'NOT_LIS_ERROR', message: String(e) });
    }
  }
}

@Controller()
export class LisController {
  constructor(private readonly svc: LisService) {}

  @Post('lis/webhook')
  async webhook(@Req() req: Request, @Res() res: Response) {
    const r = await this.svc.lis.handleWebhook(req);
    res.status(r.status).set(r.headers).send(r.body);
  }
  @Get('health') health(@Res() res: Response) { return this.svc.run(res, () => this.svc.lis.health()); }
  @Get('catalog') catalog(@Res() res: Response) { return this.svc.run(res, async () => ({ count: (await this.svc.lis.getTestTypes()).length })); }
  @Get('events') events(@Res() res: Response) { res.json(this.svc.events); }
  @Post('orders') create(@Body() body: OrderRequest, @Res() res: Response) { return this.svc.run(res, () => this.svc.lis.createOrder(body)); }
  @Get('orders/:id') get(@Param('id') id: string, @Res() res: Response) { return this.svc.run(res, () => this.svc.lis.getOrder(id)); }
  @Get('orders/:id/result') result(@Param('id') id: string, @Res() res: Response) { return this.svc.run(res, () => this.svc.lis.getResult(id)); }
  @Delete('orders/:id') del(@Param('id') id: string, @Res() res: Response) { return this.svc.run(res, () => this.svc.lis.deleteOrder(id)); }
}

@Module({ controllers: [LisController], providers: [LisService] })
class AppModule {}

NestFactory.create(AppModule, { logger: ['error', 'warn'] }).then((app) => app.listen(3000)).then(() => console.log('listening 3000'));
