BuyOrder = GLOBAL.db.BuyOrder
SellOrder = GLOBAL.db.SellOrder
MarketHelper = require "./market_helper"
async = require "async"
math = require("mathjs")
  number: "bignumber"
  decimals: 8

OrderBook =

  findBuyOrdersToMatch: (transaction, callback = ()->)->
    orderToMatchQuery =
      where:
        status:
          ne: MarketHelper.getOrderStatus "completed"
      order: [
        ["unit_price", "DESC"]
        ["created_at", "ASC"]
      ]
      attributes: ["id"]
    BuyOrder.findAll(orderToMatchQuery, {transaction: transaction}).complete callback

  findMatchingSellOrders: (buyOrderToMatch, transaction, callback = ()->)->
    matchingOrdersQuery =
      where:
        buy_currency: buyOrderToMatch.sell_currency
        sell_currency: buyOrderToMatch.buy_currency
        unit_price:
          lte: buyOrderToMatch.unit_price
        status:
          ne: MarketHelper.getOrderStatus "completed"
      order: [
        ["unit_price", "ASC"]
        ["created_at", "ASC"]
      ]
    SellOrder.findAll(matchingOrdersQuery, {transaction: transaction}).complete callback

  matchBuyOrders: (callback = ()->)->
    GLOBAL.db.sequelize.transaction (transaction)->
      OrderBook.findBuyOrdersToMatch transaction, (err, buyOrders)->
        matchOrderCallback = (o, cb)->
          OrderBook.matchBuyOrderById o.id, transaction, cb
        async.mapSeries buyOrders, matchOrderCallback, (err, result)->
          if err
            return transaction.rollback().success ()->
              console.error err
              callback err
          if result
            return transaction.commit().success ()->
              callback null, result
          callback()

  matchBuyOrderById: (id, transaction, callback = ()->)->
    BuyOrder.find(id, {transaction: transaction}).complete (err, buyOrderToMatch)->
      return err  if err
      OrderBook.findMatchingSellOrders buyOrderToMatch, transaction, (err, matchingSellOrders)->
        return err  if err
        return callback null, []  if not matchingSellOrders.length
        matchResults = OrderBook.matchMultipleOrders buyOrderToMatch, matchingSellOrders
        updateOrderCallback = (order, cb)->
          return cb null, order  if not order.changed()
          order.save({transaction: transaction}).complete cb
        async.mapSeries matchingSellOrders.concat(buyOrderToMatch), updateOrderCallback, (err, result)->
          return callback "Could not match order #{buyOrderToMatch.id} - #{JSON.stringify(err)}"  if err
          GLOBAL.db.Event.addMatchOrders matchResults, transaction, (err)->
            return callback "Could not add event for matching order #{buyOrderToMatch.id} - #{JSON.stringify(err)}"  if err
            callback null, matchResults

  matchMultipleOrders: (buyOrderToMatch, matchingSellOrders)->
    matchResults = []
    totalMatching = matchingSellOrders.length
    index = 0
    while buyOrderToMatch.left_amount > 0 and index < totalMatching
      matchResult = @matchTwoOrders buyOrderToMatch, matchingSellOrders[index]
      matchResults.push matchResult
      index++
    matchResults

  matchTwoOrders: (orderToMatch, matchingOrder)->
    amountToMatch = if matchingOrder.left_amount > orderToMatch.left_amount then orderToMatch.left_amount else matchingOrder.left_amount
    unitPrice = if matchingOrder.created_at.getTime() < orderToMatch.created_at.getTime() then matchingOrder.unit_price else orderToMatch.unit_price
    activeOrderId = if matchingOrder.created_at.getTime() > orderToMatch.created_at.getTime() then matchingOrder.id else orderToMatch.id
    matchResult = []
    matchResult.push @matchOrderAmount orderToMatch, amountToMatch, unitPrice, activeOrderId
    matchResult.push @matchOrderAmount matchingOrder, amountToMatch, unitPrice, activeOrderId
    matchResult

  matchOrderAmount: (order, amount, unitPrice, activeOrderId)->
    resultAmount = @calculateResultAmount order, amount, unitPrice
    fee = @calculateFee resultAmount
    resultAmount = math.add resultAmount, -fee
    @addMatchedAmount order, amount
    @addResultAmount order, resultAmount
    @addFee order, fee
    @adjustStatusByAmounts order
    isActive = activeOrderId is order.id
    result =
      id: order.id
      order_id: order.external_order_id
      matched_amount: amount
      result_amount: resultAmount
      fee: fee
      unit_price: unitPrice
      status: order.status
      time: Date.now()
      active: isActive

  calculateResultAmount: (order, amount, unitPrice)->
    return amount  if order.action is "buy"
    unitPrice = MarketHelper.convertFromBigint unitPrice
    math.round math.multiply(amount, unitPrice)

  calculateFee: (amount)->
    math.round math.select(amount).divide(100).multiply(MarketHelper.getTradeFee()).done(), 0

  addMatchedAmount: (order, amount)->
    order.matched_amount = math.add order.matched_amount, amount

  addResultAmount: (order, amount)->
    order.result_amount = math.add order.result_amount, amount

  addFee: (order, amount)->
    order.fee = math.add order.fee, amount

  adjustStatusByAmounts: (order)->
    return order.status = "completed"  if order.left_amount is 0
    return order.status = "partiallyCompleted"  if order.matched_amount > 0 and order.matched_amount < order.amount
    return order.status = "open"  if order.matched_amount is 0

  addOrder: (data, callback = ()->)->
    actionObject = BuyOrder  if data.action is "buy"
    actionObject = SellOrder  if data.action is "sell"
    return callback "Wrong order action type #{data.action}"  if not actionObject
    actionObject.create(data).complete callback

  deleteOpenOrder: (externalId, callback = ()->)->
    query =
      external_order_id: externalId
      status:
        ne: MarketHelper.getOrderStatus "completed"
    BuyOrder.destroy(query).complete (err, buyRows)->
      return callback err, buyRows  if err or buyRows
      SellOrder.destroy(query).complete (err, sellRows)->
        return callback err, sellRows  if err or sellRows
        callback "Could not delete order #{externalId}. Might be already completed."

exports = module.exports = OrderBook