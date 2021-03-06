import RxMultipeer
import Quick
import Nimble
import RxSwift

public class IntegrationSpec : QuickSpec {

  override public func spec() {

    var disposeBag = DisposeBag()

    describe("two clients") {

      var clientone: CurrentClient<MockIden, MockSession>!
      var clienttwo: CurrentClient<MockIden, MockSession>!

      beforeEach {
        MockSession.reset()
        disposeBag = DisposeBag()
        clientone = CurrentClient(session: MockSession(name: "one"))
        clienttwo = CurrentClient(session: MockSession(name: "two"))
      }

      describe("client two advertises") {

        beforeEach {
          // Advertise and always accept connections
          clienttwo.startAdvertising()
          clienttwo.incomingConnections()
          .subscribeNext { (client, _, respond) in
            respond(true) }
          .addDisposableTo(disposeBag)
        }

        it("allows a client to find another even if browsing is begun before advertising") {
          waitUntil { done in
            clienttwo.stopAdvertising()
            clienttwo.disconnect()
            let clientthree = CurrentClient(session: MockSession(name: "two"))
            clientone.startBrowsing()
            defer { clientthree.startAdvertising() }
            clientone.nearbyPeers()
              .filter { $0.count > 0 }
              .take(1).subscribeCompleted(done)
              .addDisposableTo(disposeBag)
          }
        }

        it("allows client one to browse for client two") {
          waitUntil { done in
            clientone.startBrowsing()
            clientone.nearbyPeers()
            .filter { $0.count > 0 }
            .subscribeNext { clients in
              expect(clients[0].0.iden).to(equal(clienttwo.iden))
              done()
            }
            .addDisposableTo(disposeBag)
          }
        }

        it("allows clients to connect with eachother") {
          waitUntil { done in
            clientone.connectedPeer()
            .take(1)
            .subscribeNext { _ in done() }
            .addDisposableTo(disposeBag)

            clientone.connect(clienttwo)
          }
        }

        it("alters connections when clients connect") {
          waitUntil { done in
            Observable.combineLatest(
              clientone.connections(),
              clienttwo.connections()) { $0.count + $1.count }
            .subscribeNext { if $0 == 2 { done() } }
            .addDisposableTo(disposeBag)

            clientone.connect(clienttwo)
          }
        }

        it("notifies connections") {
          waitUntil { done in
            Observable.zip(clientone.connectedPeer(), clienttwo.connectedPeer()) { $0 }
              .take(1)
              .subscribeNext { (two, one) in
                expect(two.iden).to(equal(clienttwo.iden))
                expect(one.iden).to(equal(clientone.iden))
                done()
              }
              .addDisposableTo(disposeBag)

            clientone.connect(clienttwo)
          }
        }

        it("notifies disconnections") {
          waitUntil { done in
            clientone.connect(clienttwo)
            Observable.zip(clientone.disconnectedPeer(), clienttwo.disconnectedPeer()) { $0 }
              .take(1)
              .subscribeNext { (two, one) in
                expect(two.iden).to(equal(clienttwo.iden))
                expect(one.iden).to(equal(clientone.iden))
                done()
              }
              .addDisposableTo(disposeBag)

            clientone.disconnect()
          }
        }

        describe("clients are connected") {

          beforeEach {
            waitUntil { done in
              clientone.connectedPeer()
              .take(1)
              .subscribeNext { _ in done() }
              .addDisposableTo(disposeBag)

              clientone.connect(clienttwo)
            }
          }

          it("allows client two to disconnect") {
            waitUntil { done in
              clientone.connections()
                .skip(1).take(1)
                .subscribeNext { (connections) in
                  expect(connections.count).to(equal(0))
                  done()
                }
                .addDisposableTo(disposeBag)

              clienttwo.disconnect()
            }
          }

          it("fires a next event when sending data") {
            waitUntil { done in
              clientone.send(clienttwo, "hello")
              .subscribeNext { _ in done() }
              .addDisposableTo(disposeBag)
            }
          }

          it("lets clients send strings to eachother") {
            waitUntil { done in
              clienttwo.receive()
              .subscribeNext { (client: Client, string: String) in
                expect(client.iden).to(equal(clientone.iden))
                expect(string).to(equal("hello"))
              }
              .addDisposableTo(disposeBag)

              clientone.send(clienttwo, "hello")
              .subscribeCompleted { done() }
              .addDisposableTo(disposeBag)
            }
          }

          it("lets clients send resource urls to each other") {
            waitUntil { done in
              clienttwo.receive()
              .subscribeNext { (client: Client, name: String, url: NSURL) in
                expect(client.iden).to(equal(clientone.iden))
                expect(name).to(equal("txt file"))
                let contents = NSString(data: NSData(contentsOfURL: url)!, encoding: NSUTF8StringEncoding)
                expect(contents).to(equal("hello there this is random data"))
              }
              .addDisposableTo(disposeBag)

              let url = NSBundle(forClass: self.dynamicType).URLForResource("Data", withExtension: "txt")
              clientone.send(clienttwo, name: "txt file", url: url!)
              .subscribeCompleted { done() }
              .addDisposableTo(disposeBag)
            }
          }

          it("lets clients send JSON data to each other via foundation objects") {
            waitUntil { done in
              clienttwo.receive()
              .subscribeNext { (client: Client, json: [String: AnyObject]) in
                expect(client.iden).to(equal(clientone.iden))
                expect(json["one"] as? String).to(equal("two"))
                expect(json["three"] as? Int).to(equal(4))
                expect(json["five"] as? Bool).to(beTrue())
              }
              .addDisposableTo(disposeBag)

              clientone.send(clienttwo, [
                "one": "two", "three": 4, "five": true])
              .subscribeCompleted { done() }
              .addDisposableTo(disposeBag)
            }
          }

          it("lets clients send streams of bytes to each other") {
            waitUntil { done in
              clienttwo.receive(clientone, streamName: "hello")
                .take(1)
                .subscribeNext { data in
                  expect(data).to(equal([0b00110011, 0b11111111]))
                  done()
                }
                .addDisposableTo(disposeBag)

              let data: Observable<[UInt8]> = Observable.of(
                [0b00110011, 0b11111111],
                [0b00000000, 0b00000001])

              Observable.zip(clientone.send(clienttwo, streamName: "hello"), data) { $0 }
                .subscribeNext { (fetcher, data) in fetcher(data) }
                .addDisposableTo(disposeBag)
            }
          }

          it("limits stream reads to the `maxLength` passed in") {
            waitUntil { done in
              clienttwo.receive(clientone, streamName: "hello")
                .take(2)
                .reduce([], accumulator: { $0 + [$1] })
                .subscribeNext { data in
                  expect(data[0].count).to(equal(512))
                  expect(data[1].count).to(equal(4))
                  done()
                }
                .addDisposableTo(disposeBag)

              let data = Observable.just([UInt8](count: 516, repeatedValue: 0x4D))

              Observable.zip(clientone.send(clienttwo, streamName: "hello"), data) { $0 }
                .subscribeNext { (fetcher, data) in fetcher(data) }
                .addDisposableTo(disposeBag)
            }

          }

        }

      }

    }

  }

}
