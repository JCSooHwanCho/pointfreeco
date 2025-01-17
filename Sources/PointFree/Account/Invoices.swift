import Dependencies
import Either
import Foundation
import HttpPipeline
import Models
import PointFreePrelude
import PointFreeRouter
import Prelude
import Stripe
import Tuple
import Views

// MARK: Middleware

let invoicesResponse =
  requireUserAndStripeSubscription
  <<< fetchInvoices
  <| writeStatus(.ok)
  >=> map(lower)
  >>> respond(
    view: Views.invoicesView(subscription:invoicesEnvelope:currentUser:),
    layoutData: { subscription, invoicesEnvelope, currentUser in
      SimplePageLayoutData(
        data: (subscription, invoicesEnvelope, currentUser),
        title: "Payment history"
      )
    }
  )

let invoiceResponse =
  requireUserAndStripeSubscription
  <<< requireInvoice
  <| writeStatus(.ok)
  >=> map(lower)
  >>> respond(
    view: Views.invoiceView(subscription:currentUser:invoice:),
    layoutData: { subscription, currentUser, invoice in
      SimplePageLayoutData(
        data: (subscription, currentUser, invoice),
        style: .minimal,
        title: "Invoice"
      )
    }
  )

private let requireInvoice:
  MT<
    Tuple3<Stripe.Subscription, User, Invoice.ID>,
    Tuple3<Stripe.Subscription, User, Invoice>
  > =
    filterMap(
      over3(fetchInvoice) >>> sequence3 >>> map(require3),
      or: redirect(to: .account(.invoices()), headersMiddleware: flash(.error, invoiceError))
    )
    <<< filter(
      invoiceBelongsToCustomer,
      or: redirect(to: .account(.invoices()), headersMiddleware: flash(.error, invoiceError))
    )

private func requireUserAndStripeSubscription<A>(
  middleware: @escaping M<T3<Stripe.Subscription, User, A>>
) -> M<T2<User?, A>> {
  filterMap(require1 >>> pure, or: loginAndRedirect)
    <<< requireStripeSubscription
    <| middleware
}

private func fetchInvoices<A>(
  _ middleware: @escaping Middleware<
    StatusLineOpen, ResponseEnded, T3<Stripe.Subscription, Stripe.ListEnvelope<Stripe.Invoice>, A>,
    Data
  >
)
  -> Middleware<StatusLineOpen, ResponseEnded, T2<Stripe.Subscription, A>, Data>
{
  @Dependency(\.stripe) var stripe

  return { conn in
    let subscription = conn.data.first

    return EitherIO {
      try await stripe.fetchInvoices(subscription.customer.id)
    }
    .withExcept(notifyError(subject: "Couldn't load invoices"))
    .run
    .flatMap {
      switch $0 {
      case let .right(invoices):
        return conn.map(const(subscription .*. invoices .*. conn.data.second))
          |> middleware
      case .left:
        return conn
          |> redirect(
            to: .account(),
            headersMiddleware: flash(.error, invoiceError)
          )
      }
    }
  }
}

private func fetchInvoice(id: Stripe.Invoice.ID) -> IO<Stripe.Invoice?> {
  @Dependency(\.stripe) var stripe

  return IO { try? await stripe.fetchInvoice(id) }
}

private let invoiceError = """
  We had some trouble loading your invoice! Please try again later.
  If the problem persists, please notify <support@pointfree.co>.
  """

private func invoiceBelongsToCustomer(_ data: Tuple3<Stripe.Subscription, User, Stripe.Invoice>)
  -> Bool
{
  return get1(data).customer.id == get3(data).customer
}
