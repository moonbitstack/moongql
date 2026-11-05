// The same schema the conformance driver serves, written for graphql-js: the
// reference implementation the responses are compared against.
import {
  GraphQLSchema,
  GraphQLObjectType,
  GraphQLInterfaceType,
  GraphQLUnionType,
  GraphQLEnumType,
  GraphQLString,
  GraphQLInt,
  GraphQLID,
  GraphQLNonNull,
  GraphQLList,
} from 'graphql';

const people = [
  { __typename: 'User', id: '1', name: 'Alice', age: 30, role: 'ADMIN', friends: [{ __typename: 'User', id: '2', name: 'Bob', age: 25, role: 'GUEST', friends: [] }] },
  { __typename: 'User', id: '2', name: 'Bob', age: 25, role: 'GUEST', friends: [] },
  { __typename: 'User', id: '3', name: 'Cara', age: 41, role: 'ADMIN', friends: [] },
];
const dune = { __typename: 'Book', title: 'Dune', isbn: '9780441013593' };

const Role = new GraphQLEnumType({
  name: 'Role',
  values: { ADMIN: {}, GUEST: {} },
});

const Node = new GraphQLInterfaceType({
  name: 'Node',
  fields: { id: { type: new GraphQLNonNull(GraphQLID) } },
  resolveType: (value) => value.__typename,
});

const User = new GraphQLObjectType({
  name: 'User',
  interfaces: [Node],
  fields: () => ({
    id: { type: new GraphQLNonNull(GraphQLID) },
    name: { type: new GraphQLNonNull(GraphQLString) },
    age: { type: GraphQLInt },
    role: { type: new GraphQLNonNull(Role) },
    friends: { type: new GraphQLNonNull(new GraphQLList(new GraphQLNonNull(User))) },
  }),
});

const Book = new GraphQLObjectType({
  name: 'Book',
  fields: {
    title: { type: new GraphQLNonNull(GraphQLString) },
    isbn: { type: new GraphQLNonNull(GraphQLString) },
  },
});

const SearchResult = new GraphQLUnionType({
  name: 'SearchResult',
  types: [User, Book],
  resolveType: (value) => value.__typename,
});

const Tick = new GraphQLObjectType({
  name: 'Tick',
  fields: { n: { type: new GraphQLNonNull(GraphQLInt) } },
});

const Query = new GraphQLObjectType({
  name: 'Query',
  fields: {
    hello: { type: new GraphQLNonNull(GraphQLString), resolve: () => 'hello' },
    user: {
      type: User,
      args: { id: { type: new GraphQLNonNull(GraphQLID) } },
      resolve: (_root, { id }) => people.find((p) => p.id === id) ?? null,
    },
    users: {
      type: new GraphQLNonNull(new GraphQLList(new GraphQLNonNull(User))),
      args: { first: { type: GraphQLInt, defaultValue: 3 } },
      resolve: (_root, { first }) => people.slice(0, first),
    },
    node: {
      type: Node,
      args: { id: { type: new GraphQLNonNull(GraphQLID) } },
      resolve: (_root, { id }) => people.find((p) => p.id === id) ?? null,
    },
    search: {
      type: new GraphQLNonNull(new GraphQLList(new GraphQLNonNull(SearchResult))),
      args: { text: { type: new GraphQLNonNull(GraphQLString) } },
      resolve: () => [people[0], dune],
    },
    fail: { type: GraphQLString, resolve: () => null },
  },
});

const Mutation = new GraphQLObjectType({
  name: 'Mutation',
  fields: {
    addUser: {
      type: new GraphQLNonNull(User),
      args: { name: { type: new GraphQLNonNull(GraphQLString) } },
      resolve: (_root, { name }) => ({
        __typename: 'User',
        id: '99',
        name,
        age: 0,
        role: 'GUEST',
        friends: [],
      }),
    },
    boom: {
      type: GraphQLString,
      resolve: () => {
        throw new Error('boom');
      },
    },
  },
});

const Subscription = new GraphQLObjectType({
  name: 'Subscription',
  fields: {
    tick: {
      type: new GraphQLNonNull(Tick),
      args: { times: { type: GraphQLInt, defaultValue: 3 } },
      subscribe: async function* (_root, { times }) {
        for (let i = 1; i <= times; i += 1) yield { n: i };
      },
      resolve: (event) => event,
    },
  },
});

export const schema = new GraphQLSchema({
  query: Query,
  mutation: Mutation,
  subscription: Subscription,
});
